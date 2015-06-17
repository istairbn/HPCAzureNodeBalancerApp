# HPCAzureNodeBalancerApp
A Logscape App that automatically grows and shrinks Azure nodes for HPC Server 2012  according to workload. SOA compatible.

###############################################################################
# HPCAzureNodeBalancerApp-1.0
# Owner: Ben Newton
# Created Date: 17/06/2015
# Contact: Ben.Newton@excelian.com
###############################################################################

This App is designed to work within Logscape - although underlying script will run without it. 

Quick Start

1. Check the bundle file, ensure that the script will be running on the Headnode of the Cluster you wish to Auto-configure
2. Deploy to your logscape environment

Files:

Lib/Azure-GrowShrinkOnDemand.ps1

The underlying script. If you do not wish to use Logscape, you may simply use this on it's own and it will happily grow your environment. The script checks the cluster for:

1. Queued Jobs - More than X and it will add nodes. Default 1.
2. Queued Calls - More than Y and it will add nodes. Default 2000.
3. Remaining Grid Minutes - More than Z and it will add nodes. Default 30.

You can configure all the parameters, including how many nodes it is grown by and how often it is checked, using the script parameters (see at the bottom of this file). 

You pass these to Logscape within the bundle file - see below. 


LOGSCAPE FILES

Directory.config - For Logscape use, simply adds output to Logscape.   
HPCAzureNodeBalancerApp-1.0.Bundle File - Controls which host the service runs on within Logscape. Notice that when running the script, you do so in quotes so that you can pass parameters to the script.
 (powerShellRunner.groovy "Azure-GrowShrinkOnDemand.ps1 -Logging False")   
powerShellRunner.groovy - A logscape script that runs the Powershell as a services.


Please find below the help synopsis for the script itself. 
<# 
   .Synopsis 
    This script is used to automatically grow and shrink PaaS Azure nodes and IaaS Azure VMs in a Microsoft HPC Pack cluster based on queued jobs, Calls remaining and minutes of work remaining. It is compatible with SOA jobs.

   .Parameter NodeTemplates
    Specifies the names of the node templates to define the scope for the nodes to grow and shrink. If not specified (the default value is @()), ALL nodes will be specified. Therefore, if you configure the $NodeType parameter, be sure to configure this to a suitable AzureNode Template.

   .Parameter JobTemplates
    Specifies the names of the job templates to define the workload for which the nodes to grow. If not specified (the default value is @()), all active jobs are in scope for check.

   .Parameter NodeType
    Specifies the node groups to grow and shrink. The default value is 'AzureNodes' for PaaS Azure burst nodes. However, you can specify other groups - if you do ensure you configure the $NodeTemplates to only grow/shrink Azure Nodes. 

   .Parameter Wait
    The time in seconds between checks to Grow or shrink. Default is 60

   .Parameter CallQueueThreshold
    The number of queued calls required to set off a growth of Nodes.Default is 2000

   .Parameter NumOfQueuedJobsToGrowThreshold
    The number of queued jobs required to set off a growth of Nodes. The default is 1. For SOA sessions, this should be set to 1 

   .Parameter GridMinsRemainingThreshold
    The time in minutes, of remaining Grid work. If this threshold is exceeded, more Nodes will be allocated. Default is 30

   .Parameter InitialNodeGrowth
    The initial minimum number of nodes to grow if all the nodes in scope are NotDeployed or Stopped(Deallocated). Default is 10

   .Parameter NodeGrowth
    The amount of Nodes to grow if there are already some Nodes in scope allocated. Compare with $NumInitialNodesToGrow. Default is 5

   .Parameter ShrinkCheckIdleTimes
    The number of continuous shrink checks to indicate that nodes are idle. Default is 3

   .Parameter Logging
    Whether the script creates a Log file or not - location determined by the LogFilePrefix. Default is True

   .Parameter LogFilePrefix
    Specifies the prefix name of the log file, you can include the path, by default the log will be in current working directory

   .Parameter ExtraNodesGrowRatio
    Specifies additional nodes to grow, because it can take a long time to start certain Azure nodes to reach a growth target. The default value is 0. For example, a value of 10 indicates that the cluster will grow 110% of the nodes.

   .Example 
    .\AzureAutoGrowShrink.ps1 -NodeTemplates @('Default AzureNode Template') -NodeType AzureNodes -NumOfQueuedJobsPerNodeToGrow 10 -NumOfQueuedJobsToGrowThreshold 1 -InitialNodeGrowth 15 -Wait 5 -NodeGrowth 3 -ShrinkCheckIdleTimes 10 

   .Example  
    .\AzureAutoGrowShrink.ps1 -NodeTemplates 'Default AzureNode Template' -JobTemplates 'Job Template 1' -NodeType APPLICATION_GROUP -CallQueueThreshold 2000 -GridMinsRemaining 50 -LogFilePrefix C:\LogFiles\MyAutoGrowShrinkLog

   .Notes 
    The prerequisites for running this script:
    1. Add the Azure nodes or the Azure VMs before running the script.
    2. This is not compatibile with the deprecated IAAS VMs. Use the Worker Roles.
    3. The HPC cluster should be running at least HPC Pack 2012 R2 Update 1

   .Link 
   www.excelian.com
#>
