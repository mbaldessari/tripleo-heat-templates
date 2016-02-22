#!/bin/bash

set -x

openstack overcloud deploy --log-file mydeploy.log --templates --libvirt-type=qemu --neutron-network-type vxlan \
  --neutron-tunnel-types vxlan --ntp-server 212.199.182.150 --control-scale 3 --compute-scale 2 --ceph-storage-scale 1 \
  --block-storage-scale 0 --swift-storage-scale 0 --control-flavor baremetal --compute-flavor baremetal \
  --ceph-storage-flavor baremetal --block-storage-flavor baremetal --swift-storage-flavor baremetal --timeout=90 \
  --templates /home/stack/openstack-tripleo-heat-templates  \
  -e /home/stack/openstack-tripleo-heat-templates/environments/network-isolation.yaml \
  -e /home/stack/openstack-tripleo-heat-templates/environments/net-single-nic-with-vlans.yaml \
  -e /home/stack/network-environment.yaml \
  -e /home/stack/openstack-tripleo-heat-templates/environments/storage-environment.yaml \
  -e /home/stack/openstack-tripleo-heat-templates/michele/userdata_env.yaml \
  -e /home/stack/openstack-tripleo-heat-templates/michele/fencing.yaml \
  -e /home/stack/openstack-tripleo-heat-templates/michele/instance-ha.yaml \
  -e /home/stack/openstack-tripleo-heat-templates/environments/puppet-pacemaker.yaml
