# WinInstall
 Scripts and configs for windows CI machines


Installing build tools on linux and macos is easy and normally a case of brew install .... or apt install .... , windows tends to be a bit more tricky and involved, this project aims to provide a scripted repeatable method of installing dependencies for windows.

Components are configured via XML files

```
<?xml version="1.0" encoding="UTF-8"?>
<package>
  <download>http://repo.msys2.org/distrib/x86_64/msys2-x86_64-20190524.exe</download>
  <command>
  	<commandline>msys2-x86_64-20190524.exe</commandline>
	<args>--platform minimal --script msys2.qs</args>
  </command>
  <path>C:\msys64\usr\bin</path>
</package>
```

This tells the installer to download the exe installer from msys2, execute it with the arguments "--platform minimal --script msys2.qs" and then add "C:\msys64\usr\bin" to the path environment variable.

There is no uninstall facility as this is designed to be used with blank virtual machines which are cloned from a template, specific components installed for the task required and then the virtual machine destroyed. Providing clean virtual machines with only the required components for the task.
