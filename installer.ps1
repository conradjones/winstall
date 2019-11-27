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
    if (!(Test-Path -Path $Output)) {
        Log -LogLevel Error -Line "Failed to download $($XmlNode.InnerText) to $Output"
        return $False
    }
    return $True
}

function Step-CreateDir($XmlNode, $RunFolder)
{
    $FolderName = $XmlNode.InnerText
    if (Test-Path -Path $FolderName) {
       if ((Get-Item $FolderName) -is [System.IO.DirectoryInfo]) {
           return $true
       }
       Log -LogLevel Error -Line "$FolderName already exists and is not a folder"
       return $False
    }
    New-Item -Path $Folder -ItemType Directory | Out-Null
    if (Test-Path -Path $FolderName) {
        Log -LogLevel Error -Line "Failed to create $FolderName"
        return $False
    }
    return $True
}

function Step-CopyFile($XmlNode, $RunFolder)
{
    $SourceNode = $XmlNode.source
    if ($Null -eq $SourceNode) {
       Log -LogLevel Error -Line "source node is missing from copy_file step"
       return $False
    }

    $DestNode = $XmlNode.dest
    if ($Null -eq $DestNode) {
       Log -LogLevel Error -Line "dest node is missing from copy_file step"
       return $False
    }

    $SourcePath = Join-Path -Path $RunFolder -ChildPath $SourceNode
    $DestPath = $DestNode 
    Copy-Item -Path $SourcePath -Destination $DestPath
    if (!(Test-Path -Path $DestPath)) {
        Log -LogLevel Error -Line "Failed to copy $SourcePath to $DestPath"
        return $False
    }
    return $True
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
            "download" { if (!(Step-Download -XmlNode $StepNode -RunFolder $RunFolder)) {exit 1} ; break}
            #"create_dir" { if (!(Step-CreateDir -XmlNode $StepNode -RunFolder $RunFolder)) {exit 1} ; break}
            "copy_file" { if (!(Step-CopyFile -XmlNode $StepNode -RunFolder $RunFolder)) {exit 1} ; break}
            default {Log -LogLevel Warn -Line "Unknown step in XML $($StepNode.LocalName)"; break}
        }
    }
}


Install-Component -ComponentName $ComponentName
