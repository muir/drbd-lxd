#!/bin/sh

dir=`dirname $0`
cmd=`basename $0`
export LD_LIBRARY_PATH=`echo $dir/../lxd/lib/*|sed s'/ /:/g'`:/usr/local/lib
exec $dir/../lxd/bin/$cmd "$@"
