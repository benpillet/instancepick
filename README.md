# instancepick
Determine which AWS EC2 instance type to use

## Install
- where does instances.json come from?
- brew install python
- https://github.com/powdahound/ec2instances.info
- file is in the www directory

## Running
- /instancepick.rb -a c4.2xlarge -t 0.8

## TODO
- Turn into a gem
- Change how it pulls and don't use the usw gem anymore
- add some specs
- make verbose output show which axis passes: cpu, mem, net_bandwidth, etc

## Design changes
- separate OS and data sources (sar) into separate classes
- separate metrics output
