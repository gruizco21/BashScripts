#!/bin/bash

# Datos de los nodos
# Nodo maestro
m1=192.168.99.10

# Nombre del adaptador privado (interno switch de nodos)
m1_eth=enp0s25
# El adaptador publico o externo hacia ForcePoint es "enp4s0"

m1_host=master

# Nodo computo 1
n1=192.168.99.201
n1_host=node1
n1_mac=00:21:70:3B:62:77

# Nodo computo 2
n2=192.168.99.202
n2_host=node2
n2_mac=00:21:70:3B:53:77

# Nodo computo 3
# n3=192.168.99.203
# n3_host=node03
# n3_mac=00:00:00:00:00:04

n_sl=node

netmask=255.255.255.0
gateway=192.168.99.1
s1=192.168.99.205
s1_host=storage1
s2=192.168.99.206
s2_host=storage2
bm1=192.168.99.230
bm1_host=beegfs-mgt

# 1. Configuraciones previas
systemctl stop firewalld && systemctl disable firewalld
sed -i 's/enforcing/disabled/' /etc/selinux/config
setenforce 0
cat >> /etc/hosts << EOF
$m1 $m1_host
$n1 $n1_host
$n2 $n2_host
# $n3 $n3_host
$s1 $s1_host
$s2 $s2_host
$bm1 $bm1_host
EOF
cp /etc/yum.repos.d/CentOS-Base.repo /etc/yum.repos.d/CentOS-Base.repo.bak
wget -O /etc/yum.repos.d/CentOS-Base.repo http://mirrors.aliyun.com/repo/Centos-7.repo
yum -y install ntp
echo "server time.windows.com perfer" >> /etc/ntp.conf
systemctl restart ntpd && systemctl enable ntpd
cat /etc/hosts
date
sleep 2

# 2. Instalar OpenHPC software y configuraciones importantes
yum -y install epel-release
yum -y install http://build.openhpc.community/OpenHPC:/1.3/CentOS_7/x86_64/ohpc-release-1.3-1.el7.x86_64.rpm
yum -y groupinstall ohpc-base ohpc-warewulf "Development tools"
yum install httpd dhcp tftp-server mod_perl
ifconfig && sleep 1
perl -pi -e "s/device = eth1/device = $m1_eth/" /etc/warewulf/provision.conf
perl -pi -e "s/^\s+disable\s+= yes/ disable = no/" /etc/xinetd.d/tftp 
systemctl restart xinetd &&  systemctl enable xinetd
systemctl restart mariadb &&  systemctl enable mariadb
systemctl restart httpd &&  systemctl enable httpd
systemctl enable dhcpd

# Establecer arranque persistente por PXE
#ipmitool -E -I lanplus -H ${bmc_ipaddr} -U root chassis bootdev pxe options=persistent 

# 3. Configuracion de slurm
yum -y install ohpc-slurm-server
lscpu && sleep 1
perl -pi -e "s/ClusterName=(\S+)/ClusterName=openHPC/" /etc/slurm/slurm.conf
perl -pi -e "s/ControlMachine=(\S+)/ControlMachine=$m1_host/" /etc/slurm/slurm.conf
perl -pi -e "s/^(#ControlAddr=)/ControlAddr=192.168.99.10/" /etc/slurm/slurm.conf
perl -pi -e "s/^NodeName=(\S+)/NodeName=$n_sl[01-03]/" /etc/slurm/slurm.conf -e "s/Sockets=2/Sockets=4/" /etc/slurm/slurm.conf
perl -pi -e "s/CoresPerSocket=8/CoresPerSocket=1/" /etc/slurm/slurm.conf
perl -pi -e "s/ThreadsPerCore=2/ThreadsPerCore=1/" /etc/slurm/slurm.conf
perl -pi -e "s/^PartitionName=(\S+)/PartitionName=nodes/" /etc/slurm/slurm.conf
perl -pi -e "s/Nodes=(\S+)/Nodes=$n_sl[01-03]/" /etc/slurm/slurm.conf
perl -pi -e "s/MaxTime=24:00:00/MaxTime=INFINITE/" /etc/slurm/slurm.conf
head -13 /etc/slurm/slurm.conf
sleep 2
tail /etc/slurm/slurm.conf
sleep 3
systemctl start slurmctld && systemctl enable slurmctld
systemctl start munge && systemctl enable munge

# 4. Definir imagen de los nodos de computo
export CHROOT=/opt/ohpc/admin/images/centos7.7
wwmkchroot centos-7 $CHROOT
sleep 1

# 5. Definir nodos de computo e instalar software OpenHPC en la imagen
cp -p /etc/resolv.conf $CHROOT/etc/resolv.conf
yum -y --installroot=$CHROOT install ohpc-base-compute 
yum -y --installroot=$CHROOT install ohpc-slurm-client 
yum -y --installroot=$CHROOT install ntp
yum -y --installroot=$CHROOT install kernel
yum -y --installroot=$CHROOT install lmod-ohpc

# Añadir nombres a fichero hosts de la imagen
cat >> $CHROOT/etc/hosts << EOF
$m1 $m1_host
$n1 $n1_host
$n2 $n2_host
# $n3 $n3_host
$s1 $s1_host
$s2 $s2_host
$bm1 $bm1_host
EOF

# 6. Crear la BD warewulf
mysqladmin -u root password 'P@ssw0rd'
perl -pi -e "s/database password   =/database password   = P@ssw0rd/" /etc/warewulf/database.conf
mysql -V && more /etc/warewulf/database.conf
sleep 2
mysql -e "create database warewulf;" -u root -p 'P@ssw0rd'
mysql -e "show databases;" -u root -p 'P@ssw0rd'
mysql -e 'grant all privileges on warewulf.* to "wwuser"@"localhost" identified by "P@ssw0rd";' -u root -p P@ssw0rd
mysql -e 'flush privileges;' -u root -p 'P@ssw0rd'
mysql -e 'select User,Host from mysql.user;' -u root -p 'P@ssw0rd'
sleep 2
systemctl restart mariadb

# 7. Definir valores basicos para OpenHPC
wwinit database
wwsh --help
wwinit ssh_keys
ls ~/.ssh/
sleep 1
cat ~/.ssh/cluster.pub >> $CHROOT/root/.ssh/authorized_keys
echo "$m1:/home /home nfs nfsvers=3,rsize=24,wsize=1024,cto 0 0" >> $CHROOT/etc/fstab
echo "$m1:/opt/ohpc/pub /opt/ohpc/pub nfs nfsvers=3 0 0" >> $CHROOT/etc/fstab
$CHROOT/bin/mkdir /beegfs_data1
$CHROOT/bin/mkdir /beegfs_data2
$CHROOT/bin/ls -ls /
sleep 2
echo "$s1:/beegfs_data1 /beegfs_data1 nfs defaults        0 0" >> $CHROOT/etc/fstab
echo "$s2:/beegfs_data1 /beegfs_data1 nfs defaults        0 0" >> $CHROOT/etc/fstab
echo "/home *(rw,no_subtree_check,fsid=10,no_root_squash)" >> /etc/exports
echo "/opt/ohpc/pub *(ro,no_subtree_check,fsid=11)" >> /etc/exports  
cat $CHROOT/etc/fstab
cat /etc/exports
sleep 3
exportfs -a
systemctl start rpcbind && systemctl enable rpcbind
systemctl restart nfs-server && systemctl enable nfs-server
chroot $CHROOT systemctl enable ntpd
echo "server $m1 perfer" >> $CHROOT/etc/ntp.conf
chroot $CHROOT systemctl start slurmd 
chroot $CHROOT systemctl enable slurmd
chroot $CHROOT systemctl start munge
chroot $CHROOT systemctl enable munge

# 8. Instalar soporte InfiniBand (opcional si no se utiliza esta tecnologia)
# yum -y groupinstall "InfiniBand Support"
# yum -y install infinipath-psm opa-basic-tools
# systemctl start rdma
# yum -y --installroot=$CHROOT groupinstall "InfiniBand Support"
# yum -y --installroot=$CHROOT install infinipath-psm opa-basic-tools libpsm2
# chroot $CHROOT systemctl enable rdma

# 9.master Add BeeGFS
wget -P /etc/yum.repos.d https://www.beegfs.io/release/beegfs_7_1/dists/beegfs-rhel7.repo
yum -y install kernel-devel gcc beegfs-client beegfs-helperd beegfs-utils
#perl -pi -e "s/^buildArgs=-j8/buildArgs=-j8 BEEGFS_OPENTK_IBVERBS=1/" /etc/beegfs/beegfs-client-autobuild.conf
/opt/beegfs/sbin/beegfs-setup-client -m $bm1
sleep 2
systemctl enable beegfs-client && systemctl enable beegfs-helperd

# 10. Añadir Ganglia
yum -y install ohpc-ganglia
yum -y --installroot=$CHROOT install ganglia-gmond-ohpc
cp /opt/ohpc/pub/examples/ganglia/gmond.conf /etc/ganglia/gmond.conf
cp: overwrite ‘/etc/ganglia/gmond.conf’? y
perl -pi -e "s/<sms>/$m1_host/" /etc/ganglia/gmond.conf
cp -f /etc/ganglia/gmond.conf $CHROOT/etc/ganglia/gmond.conf
echo "gridname openHPClab" >> /etc/ganglia/gmetad.conf

# 11. Añadir autenticacion apache
htpasswd -c /etc/httpd/auth.basic admin
cat /etc/httpd/auth.basic
sleep 1
cp /etc/httpd/conf.d/ganglia-ohpc.conf /etc/httpd/conf.d/ganglia-ohpc.conf.bak
#touch /etc/httpd/conf.d/ganglia-ohpc.conf 
cat >> /etc/httpd/conf.d/ganglia-ohpc.conf << EOF
Alias /ganglia /usr/share/ganglia-ohpc
<Location /ganglia>
  AuthType Basic
  Options None
  AllowOverride None
  Order allow,deny
  Allow from all
  AuthName "Acceso ganglia"
  AuthUserFile "/etc/httpd/auth.basic"
  Require valid-user
</Location>
EOF
systemctl start gmond && systemctl enable gmond
systemctl start gmetad && systemctl enable gmetad
chroot $CHROOT systemctl enable gmond
systemctl try-restart httpd
curl -I http://$m1/ganglia/
sleep 1

# 12. Añadir NHC(HPC health cheak)
yum -y install nhc-ohpc
yum -y --installroot=$CHROOT install nhc-ohpc
echo "HealthCheckProgram=/usr/sbin/nhc" >> /etc/slurm/slurm.conf
echo "HealthCheckInterval=300" >> /etc/slurm/slurm.conf  

# 13.Create HPC user
useradd hpcuser01 -p P@ssw0rd
useradd hpcuser02 -p P@ssw0rd
useradd hpcuser03 -p P@ssw0rd
useradd hpcuser04 -p P@ssw0rd

# 14. Importar ficheros de configuracion
wwsh -y file import /etc/passwd
wwsh -y file import /etc/group
wwsh -y file import /etc/shadow
wwsh -y file import /etc/slurm/slurm.conf
wwsh -y file import /etc/munge/munge.key
wwsh file list

# Cambiar fichero vnfs.conf (Opcional)
#sed -i "s#hybridize += /usr/lib/locale#\#hybridize += /usr/lib/locale#" /etc/warewulf/vnfs.conf
#sed -i "s#hybridize += /usr/lib64/locale#\#hybridize += /usr/lib64/locale#" /etc/warewulf/vnfs.conf
#sed -i "s#hybridize += /usr/include#\#hybridize += /usr/include#" /etc/warewulf/vnfs.conf
#sed -i "s#hybridize += /usr/share/locale#\#hybridize += /usr/share/locale#" /etc/warewulf/vnfs.conf
#cat /etc/warewulf/vnfs.conf  | grep -v "^$\|^#"
#sleep 2

# 15. Definir y preparar imagen bootstrap para nodos de computo
export WW_CONF=/etc/warewulf/bootstrap.conf
echo "drivers += updates/kernel/" >> $WW_CONF
echo "drivers += overlay" >> $WW_CONF
wwbootstrap `uname -r`
wwvnfs -y --chroot=$CHROOT

# 16. Preparar nodos de computo
echo "GATEWAYDEV=$m1_eth" > /tmp/network.$$
wwsh -y file import /tmp/network.$$ --name network
wwsh -y file set network --path /etc/sysconfig/network --mode=0644 --uid=0
wwsh -y node new $n1_host --netdev=eth0 --hwaddr=$n1_mac
wwsh -y node new $n2_host --netdev=eth0 --hwaddr=$n2_mac
#wwsh -y node new $n3_host --netdev=eth0 --hwaddr=$n3_mac
wwsh -y node set $n1_host --netdev=eth0 --ip=$n1 --netmask=$netmask --gateway=$gateway 
wwsh -y node set $n2_host --netdev=eth0 --ip=$n2 --netmask=$netmask --gateway=$gateway 
#wwsh -y node set $n3_host --netdev=eth0 --ip=$n3 --netmask=$netmask --gateway=$gateway 
wwsh -y provision set "$n_sl[01-03]" --vnfs=centos7.7 --bootstrap=`uname -r` --files=dynamic_hosts,passwd,group,shadow,slurm.conf,munge.key,network
wwvnfs --chroot $CHROOT
wwsh provision print $n1_host
wwsh file list 
sleep 2

# 17. Reiniciar varios servicios y esperar
wwsh dhcp update
systemctl restart mariadb
systemctl restart xinetd
systemctl restart httpd
systemctl restart gmond
systemctl restart gmetad
systemctl restart dhcpd
wwsh pxe update
sleep 60

# 18. Testear Cluster HPC y mostrar informacion de slurm
pdsh -w $n_sl[01-03] uptime
sinfo 
