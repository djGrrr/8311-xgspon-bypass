# bell-xgspon-bypass

## detect-config.sh
This script will help detect the settings you need for the fix-bell-vlans.sh script
It takes a optional parameter of a log file, which defaults to /root/detected-config.txt and a 2nd optional parameter of a debug log

You can set it up to run via crontab to get the settings without UART access:  
`* * * * * sh -c '/root/detect-config.sh /root/detected-config.txt /root/detected-config.log'`

## fix-bell-vlans.sh
This script will fix all the issues with multi-service vlans, can be run without knowing your Unicast VLAN but works better if you do

Configuration and it's documentation can be found at the top of the script

This is best put on a crontab to ensure the settings are applied at all times, it can be run multiple times without erroring:  
`* * * * * /root/fix-bell-vlans.sh`
