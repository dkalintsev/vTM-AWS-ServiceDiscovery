# AWS Service Discovery plugin for Pulse vTM

This is a plugin for Service Discovery feature in [Pulse Virtual Traffic Manager (vTM) v18.1 and later](https://www.pulsesecure.net/vadc/). It is designed to query AWS API using the filter specified as a parameter, and return a list of IP addresses from matching EC2 instances which vTM can use to populate the list of nodes in a pool.

Please see [blog](http://blah) post for introduction to vTM Service Discovery.

## Prerequisites

This plugin requires:

- a cluster of Pulse vTM v18.1 or later running on AWS, with one or more vTM instances
- vTMs in the cluster must have access to the Internet, to reach AWS API and optionally download dependencies
- vTM EC2 instances must have an IAM role assigned to them with the `ec2:DescribeInstances` set to `Allow`

## Parameters

The plugin takes the following parameters:

- `-f "<AWS CLI EC2 filter list>"` : a filer list conforming to AWS CLI EC2 `describe-instances` [--filters](https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-instances.html#options) syntax
- `-n <number>` : port number to return alongside the discovered IP addresses
- `[-i <number>]` : optional Network Interface Device Index, `0` by default
- `[-p]` : optional parameter telling plugin to return `Public` IP addresses of matching instances instead of default `Private`
- `[-g]` : optional parameter telling Plugin to download and install its dependencies, `jq` and `aws`

### Filters

A list of filters passed through the `-f` parameter must be enclosed in double quotes. Plugin will pass this list verbatim to the `--filters` parameter of the AWS CLI. This filter is what tells the plugin what EC2 instances are "interesting". Typically it would be one or more pairs of tag Names + Values, for example:

Tag: `ClusterID`, Value: `My-Cluster-123`, which would translate into the following filter string:

`"Name=tag:ClusterID,Values=My-Cluster-123"`

**Note**: Plugin will always add the following filter string to limit the results to only running instances:

`"Name=instance-state-name,Values=running"`

Multiple filters should be separated by spaces, e.g.:

`"Name=tag:ClusterID,Values=My-Cluster-123 Name=tag:AppComponent,Values=Backend"`

### Port Number

vTM Service Discovery expects its plugins to return a list of IP addresses of the pool nodes along with the TCP/UDP port number for each node.

Since this plugin only discovers IP addresses, it needs a port number specified explicitly through the `-n` parameter, which it will return with all IP addresses it discovers.

### Network Interface Device Index

By default, plugin will return the primary private IP address of the first network interface (Device Index = `0`) on the instances it finds.

In cases where you need to look at interfaces other than the first one, use the `-i` parameter to specify the Device Index, e.g., `-i 1` will look for the primary private IP of the second Network Interface.

### Private vs. Public IP

By default plugin will return the primary private IP address. If you need to get a Public IP, include the `-p` parameter.

### Dependency handling

Plugin requires a copy of `jq` and `aws` helper utilities to be present on the vTM to function. Neither is shipped with vTM AWS Virtual Applicance (VA) by default. You can either install these during vTM deploy, or include the `-g` parameter with this plugin's invocation.

In the later case, plugin will attempt to download `jq` into `Extras` Catalogue on vTM, and download / install AWS CLI as `/usr/local/bin/aws`. This will mean that the very first run of the plugin will take much longer to complete. When operating a multi-instance vTM cluster, plugin is executed on the cluster leader instance. When cluster leader changes (e.g., due to old cluster leader experiencing problem), very first run on the new cluster leader will be subject to the same first run delay.

If possible, install `jq` and `aws` during the vTM deploy time, using for example `cfn-init` approach as shown in [this CloudFormation template](https://github.com/dkalintsev/vADC-CloudFormation/blob/v1.1.2/Template/vADC-ASG-Puppet.template#L728) to avoid this delay.

## Usage

Refer to the [blog post](http://blah) for general introduction to vTM Service Discovery. The main difference between the K8s plugin described in that post and this one is the target of Service Discovery.

To start using it, follow these steps:

- Add this plugin to your vTM cluster's `Catalogs` -> `Service Discovery` as a `Custom User Plugin`
- Optionally test it by specifying a filter matching one or more running EC2 instances and a port number; for example:

`-f "Name=tag:ClusterID,Values=My-Cluster-123" -n 80`

If all is well, the test should return the list of matching IP(s) with port 80, something along the lines of:

> **Code:** 200
**Nodes:**
10.0.0.120:80
10.0.1.36:80

Once you've tested your plugin successfully, you can create pool(s) that use it to discover nodes.

## Limitations

- Only IPv4 is currently supported
- Plugin only discovers the EC2 instances in the same AWS Region as the vTM it runs on