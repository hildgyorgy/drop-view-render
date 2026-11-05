#define AppVersion "0.3.0"
[Setup]
AppId={{92CFA227-A47C-4FB1-9559-D076D4991E7E}
AppName=Drop & View Render
AppVersion={#AppVersion}
AppPublisher=Gyorgy Hild
DefaultDirName={localappdata}\Programs\DropViewRender
DefaultGroupName=Drop & View Render
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\artifacts
OutputBaseFilename=DropViewRender-Windows-{#AppVersion}-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\DropViewRender.Tray.exe
AppMutex=Local\DropViewRender.Tray
CloseApplications=no
RestartApplications=no

[Files]
Source: "..\artifacts\win-x64\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Drop & View Render"; Filename: "{app}\DropViewRender.Tray.exe"
Name: "{group}\Browser extension folder"; Filename: "{app}\ChromiumExtension"

[Registry]
Root: HKCU; Subkey: "Software\Google\Chrome\NativeMessagingHosts\com.hildgyorgy.dropviewrender"; ValueType: string; ValueData: "{app}\native-host.json"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Microsoft\Edge\NativeMessagingHosts\com.hildgyorgy.dropviewrender"; ValueType: string; ValueData: "{app}\native-host.json"; Flags: uninsdeletekey

[Run]
Filename: "{app}\DropViewRender.Tray.exe"; Description: "Launch Drop & View Render (tray icon)"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: files; Name: "{app}\native-host.json"
Type: filesandordirs; Name: "{localappdata}\DropViewRender\Sessions"

[Code]
function JsonEscape(Value: String): String;
begin
  StringChangeEx(Value, '\', '\\', True);
  StringChangeEx(Value, '"', '\"', True);
  Result := Value;
end;
procedure CurStepChanged(CurStep: TSetupStep);
var Id, Manifest: AnsiString; ExtensionId, HostPath: String; I: Integer;
begin
  if CurStep <> ssPostInstall then Exit;
  if not LoadStringFromFile(ExpandConstant('{app}\extension-id.txt'), Id) then RaiseException('Missing browser extension identity.');
  ExtensionId := Trim(String(Id));
  if Length(ExtensionId) <> 32 then RaiseException('Invalid browser extension identity.');
  for I := 1 to Length(ExtensionId) do
    if Pos(ExtensionId[I], 'abcdefghijklmnop') = 0 then RaiseException('Invalid browser extension identity.');
  HostPath := JsonEscape(ExpandConstant('{app}\DropViewRender.NativeHost.exe'));
  Manifest := UTF8Encode('{"name":"com.hildgyorgy.dropviewrender","description":"Drop & View Render","type":"stdio","path":"' +
    HostPath + '","allowed_origins":["chrome-extension://' + ExtensionId + '/"]}');
  if not SaveStringToFile(ExpandConstant('{app}\native-host.json'), Manifest, False) then RaiseException('Could not register native messaging.');
end;
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'DropViewRender');
end;
