#------------------------------------------------------------------------------
#Script: Azure-GrowShrinkOnDemand.ps1
#Author: Benjamin Newton - Excelian - Code Adapted from AzureAutoGrowShrink.ps1
#Version 1.0.0
#Keywords: HPC,Azure Paas, Auto grow and Shrink, Calls
#Comments:This adaptation takes Call queue and Grid time into consideration
#-------------------------------------------------------------------------------

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


param (

[Parameter (Mandatory=$False)]
[string[]] 
$NodeTemplates=@(),

[Parameter (Mandatory=$False)]
[string[]] 
$JobTemplates=@(),

[Parameter (Mandatory=$False)]
[string[]]
$NodeType="AzureNodes",

[Parameter (Mandatory=$False)]
[ValidateRange(0,[Int]::MaxValue)]
[Int] 
$Wait = 60,

[Parameter (Mandatory=$False)]
[ValidateRange(0,[Int]::MaxValue)]
[Int] 
$InitialNodeGrowth=10,

[Parameter (Mandatory=$False)]
[ValidateRange(0,[Int]::MaxValue)]
[Int] 
$NodeGrowth=5,

[Parameter (Mandatory=$False)]
[ValidateRange(0,[Int]::MaxValue)]
[Int] 
$CallQueueThreshold=2000,

[Parameter (Mandatory=$False)]
[ValidateRange(0,[Int]::MaxValue)]
[Int] 
$NumOfQueuedJobsToGrowThreshold=1,

[Parameter (Mandatory=$False)]
[ValidateRange(0,[Int]::MaxValue)]
[Int] 
$GridMinsRemainingThreshold= 40,

[Parameter (Mandatory=$False)]
[String]
$Logging=$true,

[Parameter (Mandatory=$False)]
[String]
$LogFilePrefix="Azure-GrowShrinkOnDemand",

[Parameter (Mandatory=$False)]
[ValidateRange(1,[Int]::MaxValue)]
[int]
$ShrinkCheckIdleTimes=3

)

Function GetLogFileName
{
    $datetimestr = (Get-Date).ToString("yyyyMMdd")        
    return [string]::Format("{0}_{1}.log", $LogFilePrefix, $datetimestr)
}

# Private function to log info
Function LogInfo
{
    Param (
    [String]
    $message
    )

    $LogDate=Get-Date -Format 'yyyy/MM/dd HH:mm:ss' 
    $message="$LogDate [Info] $message"

    if($Logging -eq $true)
    {
    Write-Output $message
    $message >> $(GetLogFileName)
    }
    else
    {
    Write-Host $message
    }
}

# Private function to log warning
Function LogWarning
{
    Param (
    [String]
    $message
    )

    $LogDate=Get-Date -Format 'yyyy/MM/dd HH:mm:ss'
    $message = "$LogDate[Warning] $message"

    if($Logging -eq $true)
    {
    Write-Warning -ForegroundColor Yellow $message
    $message >> $(GetLogFileName)
    }
    else
    {
    Write-Host $message
    }
}

# Private function to log error
Function LogError
{
    Param (
    [String]
    $message
    )

    $LogDate=Get-Date -Format 'yyyy/MM/dd HH:mm:ss'
    $message = "$LogDate[Error] $message"

    if($Logging -eq $true)
    {
    Write-Error -ForegroundColor Red $message
    $message >> $(GetLogFileName)
    }
    else
    {
    Write-Host $message
    }

}

$ShrinkCheck = 0
$loopcount = 0
LogInfo "Action:START Component:GrowCheck Status:Online Msg:`"Starting Azure Auto-Scaling`""

Add-PSSnapIn Microsoft.HPC;

while(1)
{

#Set initial variables for the loop 

$activeJobs = @()
$GROW = $false
$SHRINK = $false
$Duration = 0
$TotalCalls = 0
$OutstandingCalls = 0
$RunningCalls = 0
$CompletedCalls = 0
$AllocatedCores = 0

#Find running Jobs        
if ($JobTemplates.Count -ne 0)
        {
            foreach ($jobTemplate in $JobTemplates)
            {
                $activeJobs += @(Get-HpcJob -State Running,Queued -TemplateName $jobTemplate -ErrorAction SilentlyContinue -Verbose)
            }
        }

        else
        {
            $activeJobs = @(Get-HpcJob -State Running,Queued -ErrorAction SilentlyContinue -Verbose) 
        }



#Calculate current Grid Workload
foreach($job in $activeJobs)
    {
    $Duration += $job.CallDuration
    $TotalCalls += $job.NumberOfCalls
    $OutstandingCalls += $job.OutstandingCalls
    $RunningCalls += $job.CurrentAllocation
    $AllocatedCores += $job.CurrentAllocation
    }

$AvgSecs = [math]::Round(($Duration / 1000),2)
$RemainingSecs = ($AvgSecs * $OutstandingCalls)

if($AllocatedCores -eq 0)
    {
    $GridRemainingSecs = 0
    }
else
    {
    $GridRemainingSecs = [math]::Round(($RemainingSecs / $AllocatedCores),2)
    }

$GridRemainingMins = [math]::Round(($GridRemainingSecs / 60),2)
$CompletedCalls = ($TotalCalls - $OutstandingCalls)


LogInfo "Component:GrowCheck Action:REPORTING Status:Online Duration:$Duration AvgSecs:$AvgSecs TotalCalls:$TotalCalls OutstandingCalls:$OutstandingCalls CompletedCalls:$CompletedCalls RunningCalls:$RunningCalls AllocatedCores:$AllocatedCores GridRemainingMins:$GridRemainingMins GridRemainingSecs:$GridRemainingSecs"

#Check values against thresholds

if($CallQueueThreshold -ne 0){
    
    LogInfo "Component:GrowCheck Status:Online CallQueueThreshold:$CallQueueThreshold CallQueue:$OutstandingCalls"

    if($OutstandingCalls -ge $CallQueueThreshold){
        $GROW = $true
        Log-Info "Component:GrowCheck Status:Online CallQueueThreshold Exceeded"
        }
    }

if($GridMinsRemainingThreshold -ne 0 ){

    LogInfo "Component:GrowCheck Status:Online GridMinsRemainingThreshold:$GridMinsRemainingThreshold GridMinsRemaining:$GridRemainingMins"

    if($GridRemainingMins -ge $GridMinsRemainingThreshold){
        $GROW = $true
        LogInfo "Component:GrowCheck Status:Online GridMinsRemainingThreshold Exceeded"
        }
    }
    
if($NumOfQueuedJobsToGrowThreshold -ne 0){
    
    $queuedJobs = @($activeJobs | ? { $_.State -eq 'Queued' } )
    $QJobCount = $queuedJobs.Count

        LogInfo "Component:GrowCheck Status:Online QueuedJobsThreshold:$NumOfQueuedJobsToGrowThreshold QueuedJobs:$QJobCount"

    if($queuedJobs.Count -ge $NumOfQueuedJobsToGrowThreshold){
        $GROW = $true
        LogInfo "Component:GrowCheck Status:Online QueuedJobsThreshold Exceeded"
        }
    }

    LogInfo "Component:GrowCheck Status:Online Action:COMPLETE GrowState:$GROW"

if($GROW -eq $TRUE)
    {
        LogInfo "Component:NodeGrowth Status:Online Action:STARTING"
        $ShrinkCheck = 0
        $azureNodes = @();

        #Collect group of available Nodes
        if ($NodeTemplates.Count -ne 0)
        {
                $azureNodes = @(Get-HpcNode -GroupName $NodeType -TemplateName $NodeTemplates -ErrorAction SilentlyContinue -Verbose) 
        }
                else
        {
                $azureNodes = @(Get-HpcNode -GroupName $NodeType -ErrorAction SilentlyContinue -Verbose)
        }

        $targetAZNodes = @();
        $onlineAZNodes = @();

        #Find nodes not yet online or deployed
        forEach($node in $azureNodes)
            
            {
            if($node.NodeState -eq "NotDeployed" -or $node.NodeState -eq "Offline")
                {
                $targetAZNodes += $node
                }
            if($node.NodeState -eq "Online" -or $node.NodeState -eq "Provisioning")
                {
                $onlineAZNodes += $node
                }
            }

        $NodesActive = $False
        $GrowNumber = $InitialNodeGrowth
        
        #Check to see if there are any nodes currently online
        if($onlineAZNodes.Count -gt 0)
            {
            $NodesActive = $True
            $GrowNumber = $NodeGrowth
            }

        $SortedTarget = $targetAZNodes | Sort-Object NodeState,ProcessorCores,Memory
        $UndeployedTargetNodes = @()
        $OfflineTargetNodes = @()

        if($targetAZNodes.Count -gt 0){
                forEach($target in $SortedTarget[0..($GrowNumber - 1)])
                    {
                    $TName = $target.NetBiosName
                    if($target.NodeState -eq "NotDeployed")
                                                {
                LogInfo "Component:NodeGrowth Status:Online Node:$TName State:NotDeployed Action:DEPLOYING"
                $UndeployedTargetNodes += $target
                }
                    elseif($target.NodeState -eq "Offline")
                                                {
                LogInfo "Component:NodeGrowth Status:Online Node:$TName State:Offline Action:SETONLINE"
                $OfflineTargetNodes += $target
                
                        }
                    }
                #First, switch offline nodes online, then deploy new nodes
                if($OfflineTargetNodes.Count -ne 0)
                    {
                    Set-HpcNodeState -State online -Node $OfflineTargetNodes -ErrorAction SilentlyContinue -Verbose  *>> $(GetLogFileName)  
                    }

                if($UndeployedTargetNodes.Count -ne 0)
                    {
                    Start-HpcAzureNode -Node $UndeployedTargetNodes -Async $false -ErrorAction SilentlyContinue -Verbose *>> $(GetLogFileName) 
                    Set-HpcNodeState -State online -Node $UndeployedTargetNodes -ErrorAction SilentlyContinue -Verbose  *>> $(GetLogFileName) 
                    }

                }
            else
            {
            LogInfo "Component:NodeGrowth Status:Online Action:NOTHING Msg`"Grid at full capacity`""
            }

        LogInfo "Component:NodeGrowth Status:Online Action:COMPLETE Msg`"Node Growth Loop Complete`""
    }

else
    {
    LogInfo "Component:NodeGrowth Status:Online Action:NOTHING Msg:`"Growth not yet required`""
    }

#If no need to Grow, check if the Grid needs to shrink

if($GROW -eq $False)
    {
    LogInfo "Component:ShrinkCheck Status:Online Action:STARTING"
    $NodesAvailable = @();

     if ($NodeTemplates.Count -ne 0)
        {
            $NodesAvailable = @(Get-HpcNode -GroupName $NodeType -State Online,Offline -TemplateName $NodeTemplates -ErrorAction SilentlyContinue -Verbose)  
        }
        else
        {
            $NodesAvailable = @(Get-HpcNode -GroupName $NodeType -ErrorAction SilentlyContinue -State Online,Offline -Verbose)
        }

        # remove head node if in the list
     if ($NodeType -eq $NodeTypes.ComputeNodes)
        {
            $NodesAvailable = @($NodesAvailable | ? { -not $_.IsHeadNode })
        }

        $idleNodes = @();
        $NodesList = @();
        foreach ($node in $NodesAvailable)
        {
            $jobCount = (Get-HpcJob -NodeName $node.NetBiosName -ErrorAction SilentlyContinue -Verbose).Count;
            if ($jobCount -eq 0)
            {
                $idleNodes += $node;
                $NodesList += $node.NetBiosName
            }
        }
        if ($idleNodes.Count -ne 0)
        {
            $ShrinkCheck += 1
           LogInfo "Component:ShrinkCheck Status:Online Action:REPORTING IdleNodeCount:$($idleNodes.Count) IdleNodes:`"$NodesList`" ShrinkCheck:$ShrinkCheck ShrinkThreshold:$ShrinkCheckIdleTimes"
        }
        else
        {
            LogInfo "Component:ShrinkCheck Status:Online Action:REPORTING IdleNodeCount:0 ShrinkCheck:$ShrinkCheck Msg:`"Reset Shrink Counter`""
            $ShrinkCheck = 0
        }
        if($ShrinkCheck -gt $ShrinkCheckIdleTimes)
        {
        $SHRINK = $true
        }
        LogInfo "Component:ShrinkCheck Status:Online Action:COMPLETE ShrinkState:$SHRINK"
    }

if($SHRINK -eq $true)
    {
        LogInfo "Component:NodeShrink Status:Online Action:STARTING NodeCount:$($idleNodes.Count) Nodes:`"$NodesList`""
        LogInfo "Component:NodeShrink Status:Online Action:OFFLINE Msg:`"Bringing nodes offline`""
        Set-HpcNodeState -Node $idleNodes -State offline -WarningAction Ignore -ErrorAction SilentlyContinue -Verbose *>> $(GetLogFileName) 
        
        $error.Clear();
        LogInfo "Component:NodeShrink Status:Online Action:NOTDEPLOYED Msg:`"Setting Nodes to Not Deployed`""
        Stop-HpcAzureNode -Node $idleNodes -Force $false -Async $false -ErrorAction SilentlyContinue *>> $(GetLogFileName) 
            if (-not $?)
            {
                LogError "Stop Azure nodes failed."
                LogError $error
            }
            else
            {
                LogInfo "Component:NodeShrink Status:Online Action:COMPLETE Msg:`"Nodes offline`""
            }
        $ShrinkCheck = 0
    }
    else
    {
        LogInfo "Component:NodeShrink Status:Online Action:NOTHING Msg:`"Shrink not yet required`""
    }

sleep $Wait
}
