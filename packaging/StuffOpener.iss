#define AppName "Stuff Opener"
#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif
#ifndef SourceDir
  #error "SourceDir define is required."
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif
#ifndef IncludeHotkeyHelper
  #define IncludeHotkeyHelper 1
#endif

[Setup]
AppId={{A45D4255-9578-4E79-9E14-FD13CAAB56BC}
AppName={#AppName}
AppVersion={#AppVersion}
DefaultDirName={localappdata}\StuffOpener
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\StuffOpener.exe
SetupIconFile={#SourceDir}\logo_new.ico
OutputDir={#OutputDir}
OutputBaseFilename=StuffOpener-Setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional icons:"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Stuff Opener"; Filename: "{app}\StuffOpener.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\Stuff Opener"; Filename: "{app}\StuffOpener.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Registry]
#if IncludeHotkeyHelper
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "StuffOpenerHotkey"; ValueData: """{app}\stuff-opener-hotkey.exe"""; Flags: uninsdeletevalue
#endif

[Run]
#if IncludeHotkeyHelper
Filename: "{app}\stuff-opener-hotkey.exe"; Description: "Start hotkey helper"; Flags: nowait postinstall skipifsilent
#endif
Filename: "{app}\StuffOpener.exe"; Description: "Launch Stuff Opener"; Flags: nowait postinstall skipifsilent unchecked
