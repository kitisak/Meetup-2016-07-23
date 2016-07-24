
#These Parameters are loaded via octopus

#$AppVersion="1.0.11.0"
#$AppName="Hostsol.Demo.BlueGreenTestWeb"
#$SeqServerUrl=
#$HealthCheckUrl=
#$FarmName="BlueGreenDemo"

#Hardcoded servers, this was for demo, dont do this in prod
#I would recommend querying the octopus REST API instead if you want to use this
$ServersInFarm = @{
"10.0.27.113"= "Green1"; 
"10.0.27.13" = "Green2"; 
"10.0.27.67" = "Blue1"; 
"10.0.27.68" = "Blue2"}

$OnlineEnvironment="Green"

$dll=[System.Reflection.Assembly]::LoadWithPartialName("Microsoft.Web.Administration")

#Below funcitons controll ARR
#I would personally recommend using nginx instead 
#  and using a SSH conencitons from the ocotpus server to control
#  ARR was used in this demo simply for an easy setup
function GetWebFarm {  param([string]$FarmName )    #Get the manager and config object
    $mgr = new-object Microsoft.Web.Administration.ServerManager
    $conf = $mgr.GetApplicationHostConfiguration()
    #Get the webFarms section
    $section = $conf.GetSection("webFarms")
    return $section.GetCollection() | Where { $_.GetAttributeValue("name") -eq $FarmName }
 }        

function TakeServerOffline {  param([string]$ServerName )    $arr = GetServerARR($ServerName);
    $method = $arr.Methods["SetState"]
    $methodInstance = $method.CreateInstance()
    $methodInstance.Input.Attributes[0].Value = 2
    $methodInstance.Execute()
    Write-Host "Killing $ServerName"  }
 
function BringServerOnline {  param([string]$ServerName )              $arr = GetServerARR($ServerName);
            $method = $arr.Methods["SetState"]
            $methodInstance = $method.CreateInstance()
            $methodInstance.Input.Attributes[0].Value = 0
            $methodInstance.Execute()
            Write-Host "Living $ServerName" }
 
 function GetServerARR()
 {  param([string]$ServerAddress )
  Write-Host "GetServerARR for $ServerName"
   $webFarm =   GetWebFarm($FarmName);
   $servers = $webFarm.GetCollection();
   $server = $servers | Where { $_.GetAttributeValue("address") -eq $ServerAddress };
   $arr = $server.GetChildElement("applicationRequestRouting")
   return $arr;
 }
 
function GetFarmStatus()
{  param([string]$FarmName )
   $webFarm =   GetWebFarm($FarmName);
   $servers = $webFarm.GetCollection();
    foreach($server in $servers)
    {
        $arr = $server.GetChildElement("applicationRequestRouting")
       
         $ip= $server.GetAttributeValue("address")
         #Get the ARR section
         $arr = $server.GetChildElement("applicationRequestRouting")
         $counters = $arr.GetChildElement("counters")
            
            
         $isHealthy=$counters.RawAttributes["isHealthy"]
            
         $state= $counters.RawAttributes["state"]
      
         switch ($state) 
         { 
                0 {$state= "Available"} 
                1 {$state= "Drain"} 
                2 {$state= "Unavailable"} 
                default {$state= "Non determinato"}
         }
 
        if( $isHealthy)
        {
            $isHealthy="Healthy"
        }
        else
        {
            $isHealthy="Not Healthy"
        }        

        #0 -> Available
        #1 -> Drain
        #2 -> Unavailable
        #3 -> Unavailable

         Write-Host -NoNewLine $ip  " " $state " " $isHealthy
         #NEW LINE
         Write-Host
    }
    #NEW LINE
    Write-Host
}

function GetOnlineEnvironment()
{  param([string]$FarmName )

   $webFarm =   GetWebFarm($FarmName);
   $servers = $webFarm.GetCollection();
    #determin which Environment is live based on status of 2
    foreach($server in $servers)
    {
    $addy = $server.GetAttributeValue("address").ToString();
    $ServerName = $ServersInFarm.Get_Item($addy)
    $arr = $server.GetChildElement("applicationRequestRouting")
    $counters = $arr.GetChildElement("counters")
    $state= $counters.RawAttributes["state"]
     if($ServerName.EndsWith("2"))#dodgy check, dont write code like this for prod
     {
        if($state -eq 0)
        {
            if($ServerName.StartsWith("Green"))
            {
            $OnlineEnvironment="Green"
            }
            else
            {
            $OnlineEnvironment="Blue"
            }
        }
     }
    }
    Write-Host "Online Environment is $OnlineEnvironment"
    return $OnlineEnvironment;
   }

   GetFarmStatus("BlueGreenDemo");

   $online = GetOnlineEnvironment("BlueGreenDemo");
   $offline = if($online -eq "Green") { "Blue" } else {"Green"}; 
   Write-Host "Offline Environment is $offline"

   #get the offline environment number 1 server
   $OfflineServers = $ServersInFarm.GetEnumerator() | ?{ $_.Value.ToString().StartsWith($offline) }
   $OnlineServers = $ServersInFarm.GetEnumerator() | ?{ $_.Value.ToString().StartsWith($online) }
   $Canary = $OfflineServers.GetEnumerator() | ?{ $_.Value.ToString().EndsWith("1") }

   #online this server
   Write-Host "My Canary is $Canary"
   BringServerOnline($Canary.Key)

   GetFarmStatus("BlueGreenDemo");
   #wait 1 minute
   Write-Host "Waiting 1 minute for real traffic"
   Start-Sleep -s 60

   #query seq
   $resp = Invoke-WebRequest "$SeqServerUrl/api/events/signal?intersectIds=&filter=And%28And%28Equal%28AppVersion%2C%22$AppVersion%22%29%2CEqual%28AppName%2C%22$AppName%22%29%29%2CEqual%28%40Level%2C%22Error%22%29%29&count=50&shortCircuitAfter=1000" -UseBasicParsing   $EventData=($resp.Content | ConvertFrom-Json).Events

   Write-Host "$SeqServerUrl/api/events/signal?intersectIds=&filter=And%28And%28Equal%28AppVersion%2C%22$AppVersion%22%29%2CEqual%28AppName%2C%22$AppName%22%29%29%2CEqual%28%40Level%2C%22Error%22%29%29&count=50&shortCircuitAfter=1000" 
   # fail offline number 1 throw
   if($EventData.Count -gt 2)
   {
   $ErrorCount = $EventData.Count
     Write-Host "EXPLODE! I got $ErrorCount or more Errors"
       Write-Host "TakeServerOffline " + $Canary.Key
     TakeServerOffline($Canary.Key)
     throw "EXPLODE! I got $ErrorCount or more Errors"
   }
   else
   {
   Write-Host "Everything is ok"
   Write-Host "Any servers that are not online bring online"
   # success online number 2 and offline live environment
    foreach($OfflineServer in $OfflineServers)
       {
           if($OfflineServer.Key -ne $Canary.Key)
           {
           Write-Host "BringServerOnline " + $OfflineServer.Key
           BringServerOnline($OfflineServer.Key);
           }
       }
        Write-Host "All servers that are online in old Env take offline"
       foreach($OnlineServer in $OnlineServers)
       {
       Write-Host "TakeServerOffline " + $OnlineServer.Key
       TakeServerOffline($OnlineServer.Key)
       }
   }
   
   GetFarmStatus("BlueGreenDemo");
