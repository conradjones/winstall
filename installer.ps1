param([Parameter(Mandatory=$true)][String]$ComponentName)

$scriptPath = split-path -parent $MyInvocation.MyCommand.Definition

enum LogLevel
{
    Info
    Debug
    Error
    Warn
}

function Log ([LogLevel]$LogLevel, $Line)
{
    $LogLevel.ToString() + ":" + $Line | Out-Host
}


function Get-RunFolder($ComponentName)
{
    $Folder = "C:\Temp\$ComponentName"
    Remove-Item -Path $Folder -Recurse -Force | Out-Null
    New-Item -Path $Folder -ItemType Directory | Out-Null
    return $Folder
}

function Step-Download($XmlNode, $RunFolder)
{
    $FileName = $XmlNode.InnerText  | Split-Path -Leaf 
    $Output = Join-Path -Path $RunFolder -ChildPath $FileName
    $WebClient = New-Object System.Net.WebClient
    "Downloading:$($XmlNode.InnerText)" | Out-Host 
    $WebClient.DownloadFile($XmlNode.InnerText, $Output)
}

function Step-CreateDir($XmlNode, $RunFolder)
{

}

function Step-CopyFile($XmlNode, $RunFolder)
{

}

function Step-Path($XmlNode, $RunFolder)
{

}


function Install-Component($ComponentName)
{

    $ComponentPath = Join-Path -Path $scriptPath -ChildPath $ComponentName
    if (!(Test-Path -Path $ComponentPath)) {
        Log -LogLevel Error  -Line "Failed to find $ComponentPath"
        return
    }
    $ComponentXMLPath = Join-Path -Path $ComponentPath -ChildPath "install.xml"
    if (!(Test-Path -Path $ComponentXMLPath)) {
        Log -LogLevel Error  -Line "Failed to find $ComponentXMLPath"
        return
    }
    [xml]$XmlDocument = Get-Content -Path $ComponentXMLPath
    if ($null -eq $XmlDocument) {
        Log -LogLevel Error  -Line "Failed to find parse $ComponentXMLPath"
        return
    }

    $PackageNode = $XmlDocument.package
    if ($null -eq $PackageNode) {
        Log -LogLevel Error  -Line "Failed to find package node in $ComponentXMLPath"
        return
    }

    $RunFolder = Get-RunFolder -ComponentName $ComponentName

    foreach ($StepNode in $PackageNode.ChildNodes) {
        switch ($StepNode.LocalName) {
            "download" { Step-Download -XmlNode $StepNode -RunFolder $RunFolder ; break}
            default {Log -LogLevel Warn -Line "Unknown step in XML $($StepNode.LocalName)"; break}
        }
    }
}


Install-Component -ComponentName $ComponentName
