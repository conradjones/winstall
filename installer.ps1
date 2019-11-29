param([Parameter(Mandatory=$true)][String]$ComponentPath)

$ErrorActionPreference = “Stop”

enum LogLevel
{
    Info
    Debug
    Error
    Warn
}

function Log ([LogLevel]$LogLevel, $Line)
{
    $Line = $LogLevel.ToString() + ":" + $Line
    switch ($LogLevel) {
        Info    { Write-Verbose  -Message $Line -Verbose }
        Debug   { Write-Debug    -Message $Line }
        Error   { Write-Error    -Message $Line }
        Warn    { Write-Warning  -Message $Line }
    }
}

function Get-RunFolder($ComponentName)
{
    $Folder = "C:\Temp\$ComponentName"
    if (Test-Path -Path $Folder) {
        Remove-Item -Path $Folder -Recurse -Force | Out-Null
    }
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
    New-Item -Path $FolderName -ItemType Directory | Out-Null
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
    $PathToAdd = $XmlNode.InnerText
    $PathKeyValue = (Get-ItemProperty -Path 'Registry::HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\Session Manager\Environment' -Name PATH).path
    $AllPaths = $PathKeyValue.split(";")
    if ($AllPaths.Contains($PathToAdd)) {
        Log -LogLevel Info -Line "System path variable already includes:$PathToAdd"
        return $True
    }
    $AllPaths += $PathToAdd
    $PathKeyValue = $AllPaths -join ';'
    Set-ItemProperty -Path 'Registry::HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\Session Manager\Environment' -Name PATH -Value $PathKeyValue -Force
    $PathKeyValue = (Get-ItemProperty -Path 'Registry::HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\Session Manager\Environment' -Name PATH).path
    if (!($PathKeyValue.Contains($PathToAdd))) {
        Log -LogLevel Info -Line "Failed to add:$PathToAdd to System path variable"
        return $False
    }
    return $True
}

function Step-Command($XmlNode, $RunFolder)
{
    Push-Location -Path $RunFolder
    $command = $XmlNode.commandLine
    $args = @()
    foreach ($ArgNode in $XmlNode.args.arg) {
        $args += $ArgNode
    }
    $argString = $args -join " "
    Log -LogLevel Info -Line "Executing:$command $argString"
    Start-Process -FilePath $command -ArgumentList $args -Wait
    Pop-Location
    return $True
}

function Step-RegSet($XmlNode, $RunFolder)
{
    $RegKey = $XmlNode.key
    $RegValue = $XmlNode.value
    $RegValueName = $XmlNode.value_name

    switch ($XmlNode.value_type) {
        "REG_DWORD" { $Type = [Microsoft.Win32.RegistryValueKind]::DWord}
        "REG_SZ"    { $Type = [Microsoft.Win32.RegistryValueKind]::String}
        default     { return $false }
    }

    [Microsoft.Win32.Registry]::SetValue($RegKey,$RegValueName,$RegValue,$Type)

    return $True
}

function Confirm-FileDetected($DetectionNode, $RunFolder)
{
    if (!(Test-Path -Path $DetectionNode.path)) {
        Log -LogLevel Debug -Line "(Detection):$($DetectionNode.path) not found"
        return $False
    }

    if (!((Get-Item $DetectionNode.path) -is [System.IO.FileInfo])) {
        Log -LogLevel Debug -Line "(Detection):$($DetectionNode.path) found but is not a file"
        return $False
    }

    $expectedVersion = $DetectionNode.version
    if ($null -ne $expectedVersion) {
        $foundVersion = (Get-Command $DetectionNode.path).Version
        if ($foundVersion -ne [version]$expectedVersion) {
            Log -LogLevel Debug -Line "(Detection):$($DetectionNode.path) found but version is:$foundVersion (expected:$expectedVersion)"
            return $False
        }
    }

    return $True
}

function Confirm-PowershellDetected($DetectionNode, $RunFolder)
{
    $scriptBlock = $DetectionNode.scriptblock
    if ($null -eq $scriptBlock) {
        Log -LogLevel Info -Line "Powershell detection node missing scriptblock"
        exit 1
    }

    $expected = $DetectionNode.expected
    if ($null -eq $expected) {
        Log -LogLevel Info -Line "Powershell detection node missing expected"
        exit 1
    }

    $Result = Invoke-Expression -Command $scriptBlock

    return ($Result -eq $expected)
}

function Confirm-IsDetected($XmlNode, $RunFolder)
{
    foreach ($DetectionNode in $XmlNode.ChildNodes) {
        switch ($DetectionNode.LocalName) {
            "file"          { if (!(Confirm-FileDetected        -DetectionNode $DetectionNode -RunFolder $RunFolder)) {return $false} ; break}
            "powershell"    { if (!(Confirm-PowershellDetected  -DetectionNode $DetectionNode -RunFolder $RunFolder)) {return $false} ; break}
            default  {Log -LogLevel Warn -Line "Unknown detection step in XML $($DetectionNode.LocalName)"; exit 1}
        }
    }
    return $True
}

function Install-Component($ComponentPath)
{
    $ComponentName = Split-Path -Path $ComponentPath -Leaf

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
    Log -LogLevel Info  -Line "Package:$ComponentName runfolder:$RunFolder"

    $DetectionNode = $PackageNode.detect
    if ($null -ne $DetectionNode ) {
        if (Confirm-IsDetected -XmlNode $DetectionNode -RunFolder $RunFolder) {
            Log -LogLevel Info  -Line "Package is detected:$ComponentName"
            return $True
        }
    }

    Log -LogLevel Info  -Line "Installing package:$ComponentName"

    foreach ($StepNode in $PackageNode.steps.ChildNodes) {
        switch ($StepNode.LocalName) {
            "download"   { if (!(Step-Download  -XmlNode $StepNode -RunFolder $RunFolder)) {exit 1} ; break}
            "create_dir" { if (!(Step-CreateDir -XmlNode $StepNode -RunFolder $RunFolder)) {exit 1} ; break}
            "copy_file"  { if (!(Step-CopyFile  -XmlNode $StepNode -RunFolder $RunFolder)) {exit 1} ; break}
            "path"       { if (!(Step-Path      -XmlNode $StepNode -RunFolder $RunFolder)) {exit 1} ; break}
            "command"    { if (!(Step-Command   -XmlNode $StepNode -RunFolder $RunFolder)) {exit 1} ; break}
            "reg_set"    { if (!(Step-RegSet    -XmlNode $StepNode -RunFolder $RunFolder)) {exit 1} ; break}
            default {Log -LogLevel Warn -Line "Unknown step in XML $($StepNode.LocalName)"; break}
        }
    }

    if ($null -ne $DetectionNode ) {
        if (!(Confirm-IsDetected -XmlNode $DetectionNode -RunFolder $RunFolder)) {
            Log -LogLevel Error  -Line "Package is not detected after install $ComponentName"
            return $False
        }
        Log -LogLevel Info  -Line "Post install package is detected $ComponentName"
    }

    return $True
}


Install-Component -ComponentPath $ComponentPath
