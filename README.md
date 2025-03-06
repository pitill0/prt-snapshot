# prt-snapshot
Snapshots manager for prt-get

## DESCRIPTION
  Make status snapshots of installed packages and manage them with prt-get


## REQUERIMENTS
  - bash    (http://cnswww.cns.cwru.edu/~chet/bash/bashtop.html)
  - prt-get (http://jw.smts.ch/files/crux/prt-get_quickstart.html)

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
