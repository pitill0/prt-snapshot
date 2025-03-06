# prt-snapshot
Snapshots manager for prt-get

## DESCRIPTION
  Make status snapshots of installed packages and manage them with prt-get


## REQUERIMENTS
### Software
  - bash    (https://tiswww.case.edu/php/chet/bash/bashtop.html)
  - prt-get (https://git.crux.nu/tools/prt-get)
### Work directory
  ```sudo mkdir -p /var/lib/pkg/snapshots```

## USAGE
```
  prt-snapshot <command> [options]
  Where commands are:
  clean         Remove all stored snapshots
  store    msg  Take an snapshot of installed ports
  restore  num  Restore to a status defined by certain snapshot
  diff     num  Return differences between current status and a snapshot
  list          List all stored snapshots
  help          Show this help information
  version       Show version information
```

## BUGS AND REPORTS
Please contact to:
* > Victor Martinez: ```pitillo at crux-arm dot nu```
* > Jose V Beneyto: ```sepen at crux dot nu```
