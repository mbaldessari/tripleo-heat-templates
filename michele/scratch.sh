#!/bin/bash
set -x

function wait_for_introspection()
{
  uuid=$1
  count=0
  while true; do
    ret=$(openstack baremetal introspection status $uuid |grep finished| awk '{ print $4 }')
    if [ $ret == "True" ]; then
      break
    fi
    sleep 4
    count=$(($count + 1))
    if [ $count -gt 40 ]; then
      echo "Node $uuid - $count had an error"
      exit -1
    fi
  done
}


failed=$(sudo systemctl | grep -v ipmiev | grep -i failed)
ret=$?

if [ $ret == 0 ]; then
  echo "Some services are in failed state: $failed"
  echo $ret
  exit 1
fi

#heat stack-delete overcloud
#sleep 2

echo "Removing overcloud first"
while true; do
  heat stack-list | grep overcloud
  if [ $? != 0 ]; then
    echo "Overcloud deleted"
    break
  fi
  heat stack-list | grep "DELETE_FAILED"
  if [ $? == 0 ]; then
    echo "Overcloud deletion failed"
    exit 1
  fi
  sleep 4
done

set -e

echo "Injecting current puppet modules"
virt-customize -a overcloud-full.qcow2 --delete /usr/share/openstack-puppet/modules/ 
virt-copy-in -a overcloud-full.qcow2 /home/stack/modules /usr/share/openstack-puppet/

#echo "Setting default password for images"
#virt-customize -a overcloud-full.qcow2 --root-password password:Redhat01

echo "reupload glance images"
for i in $(glance image-list | grep active | awk '{print $2}'); do
echo $i
glance image-delete "$i"
done

openstack overcloud image upload --image-path ~
for i in `ironic node-list --detail  | grep pxe | awk '{ print $(NF-3)}'`; do echo $i; ironic node-delete $i; done
openstack baremetal import --json instackenv.json
openstack baremetal configure boot
ids="$(ironic node-list --detail | grep pxe_ssh | awk '{print $(NF-3)}')"
for i in $ids; do
  ironic node-set-provision-state "$i" manage
  openstack baremetal introspection start "$i"
  wait_for_introspection "$i"
done
openstack flavor set --property "cpu_arch"="x86_64" --property "capabilities:boot_option"="local" --property "capabilities:profile"="baremetal" baremetal
ids="$(ironic node-list --detail | grep pxe_ssh | awk '{print $(NF-3)}')"
echo $ids
for i in $ids; do 
  echo "Updating node $i"
  ironic node-set-provision-state "$i" provide
  ironic node-update $i replace properties/capabilities='profile:baremetal,boot_option:local'
done

