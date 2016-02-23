#!/bin/bash
set -e

base=$(dirname $0)

function wait_for_heat_delete()
{
  count=0
  while true; do
    ret=$(heat stack-list |grep overcloud | awk '{ print $6 }')
    echo -n "."
    if [ "x$ret" == "xDELETE_FAILED" ]; then
      echo "Deleting overcloud failed. Exiting"
      exit -1
    fi
    if [ "x$ret" == "x" ]; then
      echo "Overcloud deleted successfully"
      break
    fi
    sleep 4
    count=$(($count + 1))
    if [ $count -gt 40 ]; then
      echo "Waited for too long $count"
      exit -1
    fi
  done
  echo ""
}


echo "Deleting overcloud"
#heat stack-delete overcloud
wait_for_heat_delete

echo "overcloud stackdeleted"

$base/scratch.sh && $base/deploy.sh
