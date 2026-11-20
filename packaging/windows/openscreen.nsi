; NSIS Modern User Interface script for OpenScreen
!include "MUI2.nsh"
!include "FileFunc.nsh"

Name "OpenScreen"
OutFile "..\..\dist\OpenScreen-NSIS-Setup-x64.exe"
InstallDir "$PROGRAMFILES64\OpenScreen"
InstallDirRegKey HKLM "Software\OpenScreen" "Install_Dir"
RequestExecutionLevel admin

!define MUI_ABORTWARNING
!define MUI_ICON "..\..\packaging\openscreen.ico"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "..\..\LICENSE"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

Section "OpenScreen (required)" SecCore
  SectionIn RO
  SetOutPath "$INSTDIR"
  File "..\..\zig-out\bin\openscreen.exe"
  File /nonfatal "..\..\*.dll"
  File "..\..\LICENSE"
  File "..\..\THIRD-PARTY-NOTICES.md"
  
  SetOutPath "$INSTDIR\assets"
  File /r "..\..\assets\*.*"

  ; Create shortcuts
  CreateDirectory "$SMPROGRAMS\OpenScreen"
  CreateShortcut "$SMPROGRAMS\OpenScreen\OpenScreen.lnk" "$INSTDIR\openscreen.exe"
  CreateShortcut "$SMPROGRAMS\OpenScreen\Uninstall.lnk" "$INSTDIR\Uninstall.exe"
  CreateShortcut "$DESKTOP\OpenScreen.lnk" "$INSTDIR\openscreen.exe"

  ; File association
  WriteRegStr HKCR ".openscreen" "" "OpenScreen.Project"
  WriteRegStr HKCR "OpenScreen.Project" "" "OpenScreen Project"
  WriteRegStr HKCR "OpenScreen.Project\DefaultIcon" "" "$INSTDIR\openscreen.exe,0"
  WriteRegStr HKCR "OpenScreen.Project\shell\open\command" "" '"$INSTDIR\openscreen.exe" "%1"'

  ; Write uninstaller
  WriteUninstaller "$INSTDIR\Uninstall.exe"
SectionEnd

Section "Uninstall"
  Delete "$DESKTOP\OpenScreen.lnk"
  Delete "$SMPROGRAMS\OpenScreen\*.*"
  RMDir "$SMPROGRAMS\OpenScreen"
  RMDir /r "$INSTDIR"
  DeleteRegKey HKCR ".openscreen"
  DeleteRegKey HKCR "OpenScreen.Project"
SectionEnd
