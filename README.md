# fluent-plugin-winevtlog

## Component

#### fluentd Input plugin for Windows Event Log

[Fluentd](http://fluentd.org) plugin to read Windows Event Log.
You must use fluentd 'Windows' brach to use this, and this doesn't work on Linux of course.
.


## Configuration
#### fluentd Input plugin for Windows Event Log 

    <source>
      type winevtlog
      channel application,system
      pos_file c:\temp\mypos
      read_interval 2
      tag winevt.raw
    </source>
    

#### parameters

|name      | description |
|:-----    |:-----       |              
|channel   | (option) 'applicaion' as default. one or combination of {application, system, setup, security}. If you want to read setup or security, administrator priv is required to launch fluentd.  |
|pos_file  | (option, but higly recommended) a path of position file to save record numbers. |
|read_interval   | (option) a read interval in second. 2 seconds as default.|


#### read keys
This plugin reads follows from Windws Event Log. No customization is allowed currently.

|key|
|:-----    |
|record_number   |
|time_generated|
|time_written   |
|event_id   |
|event_type   |
|event_category   |
|source_name   |
|computer_name  |
|user   |
|description   |
.


## Etc.
'read_from_head' is not supporeted currently.You can read newer records after you start first.
No customize to read information keys.
.



## Copyright
####Copyright
Copyright(C) 2014- @okahashi117
####License
Apache License, Version 2.0
.
