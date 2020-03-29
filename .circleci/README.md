
# automated testing

We've enabled automated test runs for all major releases of bash that bats-core supports (bash 3.2 and above).

Getting lsblk installed on old releases of linux is difficult so we use alpine containers to test bash 4.0 and 3.2

| job          | bash ver | bash released | df information     |
|--------------|----------|---------------|--------------------|
| deb10buster  | 5.0      | Jan 2019      | GNU coreutils 8.30 |
| deb09stretch | 4.4      | Sep 2016      | GNU coreutils 8.26 |
| vm           | 4.3      | Feb 2014      | GNU coreutils 8.25 |
| deb08jessie  | 4.3      | Feb 2014      | GNU coreutils 8.23 |
| cryptsetup   | 4.3      | Feb 2014      | BusyBox v1.26.2    |
| deb07wheezy  | 4.2      | Feb 2011      | GNU coreutils 8.13 |
| deb06squeeze | 4.1      | Dec 2009      | GNU coreutils 8.5  |
| bash_4_0     | 4.0      | Feb 2009      | BusyBox v1.31.1    |
| bash_3_2     | 3.2      | Oct 2006      | BusyBox v1.31.1    |
