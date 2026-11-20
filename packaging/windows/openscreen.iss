; Inno Setup Script for OpenScreen
#define MyAppName "OpenScreen"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "OpenScreen Contributors"
#define MyAppURL "https://github.com/getopenscreen/openscreen"
#define MyAppExeName "openscreen.exe"

[Setup]
AppId={{5E4700F9-C163-4CD0-B95D-80FECA63DF45}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={autopf}\{#MyAppName}
DisableProgramGroupPage=yes
LicenseFile=..\..\LICENSE
OutputDir=..\..\dist
OutputBaseFilename=OpenScreen-Setup-x64
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "addtopath"; Description: "Add OpenScreen to system PATH (for headless CLI & MCP server)"; GroupDescription: "System Integration:"; Flags: unchecked

[Files]
Source: "..\..\zig-out\bin\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\*.dll"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "..\..\assets\*"; DestDir: "{app}\assets"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\..\LICENSE"; DestDir: "{app}"; DestName: "LICENSE.txt"; Flags: ignoreversion
Source: "..\..\THIRD-PARTY-NOTICES.md"; DestDir: "{app}"; DestName: "THIRD-PARTY-NOTICES.txt"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[Registry]
Root: HKA; Subkey: "Software\Classes\.openscreen"; ValueType: string; ValueName: ""; ValueData: "OpenScreen.Project"; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\OpenScreen.Project"; ValueType: string; ValueName: ""; ValueData: "OpenScreen Project"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\OpenScreen.Project\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\{#MyAppExeName},0"
Root: HKA; Subkey: "Software\Classes\OpenScreen.Project\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#MyAppExeName}"" ""%1"""
