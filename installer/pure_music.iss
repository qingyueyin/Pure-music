#ifndef SourceDir
  #error SourceDir is required
#endif
#ifndef AppVersion
  #error AppVersion is required
#endif

#define AppName "Pure Music"
#define AppExeName "pure_music.exe"

[Setup]
AppId={{42C4470A-72BE-49A0-B32F-DF7A941DD48C}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=qingyueyin
AppPublisherURL=https://github.com/qingyueyin/Pure-music
AppSupportURL=https://github.com/qingyueyin/Pure-music/issues
AppUpdatesURL=https://github.com/qingyueyin/Pure-music/releases
AppContact=qingyueyin
AppComments=Windows 本地音乐播放器
AppCopyright=Copyright (C) 2026 qingyueyin
DefaultDirName={localappdata}\Programs\{#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=.
OutputBaseFilename=pure_music_installer
SetupIconFile=..\app_icon.ico
UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\{#AppExeName}
VersionInfoDescription={#AppName} 安装程序
VersionInfoCompany=qingyueyin
VersionInfoCopyright=Copyright (C) 2026 qingyueyin
VersionInfoProductName={#AppName}
VersionInfoProductVersion={#AppVersion}
VersionInfoVersion={#AppVersion}.0
WizardStyle=modern dynamic
DisableWelcomePage=no
DisableReadyPage=no
ShowLanguageDialog=no
CloseApplications=yes
RestartApplications=no
Compression=lzma2/max
SolidCompression=yes
SetupLogging=yes

[Languages]
Name: "zhcn"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Messages]
zhcn.TranslatorNote=

[CustomMessages]
PortableDataTitle=导入便携版数据
PortableDataDescription=是否迁移原便携版中的个人数据？
PortableDataSubCaption=此步骤可选。安装程序只会迁移设置、媒体库、播放列表和歌词来源记录，不会修改原文件。
PortableDataOption=从原便携版导入个人数据(&I)
PortableDataPathTitle=选择便携版位置
PortableDataPathDescription=原便携版位于哪个文件夹？
PortableDataPathSubCaption=请选择包含 pure_music.exe 的原便携版文件夹。
PortableDataInvalid=所选文件夹不是完整的 Pure Music 便携版目录，请重新选择。
PortableDataImporting=正在导入便携版数据...
PortableDataImportFailed=Pure Music 已安装完成，但便携版数据导入失败。原便携版数据没有被修改，可稍后重新迁移。
DesktopIcon=创建桌面快捷方式(&D)
DeleteUserDataPrompt=是否同时删除设置、媒体库索引、播放列表、歌词来源记录和缓存？%n%n选择“否”会保留这些数据，便于以后重新安装。
DeleteUserDataFailed=部分用户数据未能删除，请关闭仍在使用 Pure Music 数据的程序后手动清理：%n%n%1

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "import_portable_data.ps1"; Flags: dontcopy

[Tasks]
Name: "desktopicon"; Description: "{cm:DesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[InstallDelete]
Type: filesandordirs; Name: "{autoprograms}\{#AppName}"

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Pure Music"; ValueType: string; ValueName: "InstallLocation"; ValueData: "{app}"; Flags: uninsdeletekey

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[Code]
var
  PortableDataChoicePage: TInputOptionWizardPage;
  PortableDataPathPage: TInputDirWizardPage;
  PortableSourceData: String;

function DirectoryHasEntries(const Path: String): Boolean;
var
  FindRec: TFindRec;
begin
  Result := False;
  if not DirExists(Path) then
    Exit;

  if FindFirst(AddBackslash(Path) + '*', FindRec) then
  begin
    try
      repeat
        if (FindRec.Name <> '.') and (FindRec.Name <> '..') then
        begin
          Result := True;
          Exit;
        end;
      until not FindNext(FindRec);
    finally
      FindClose(FindRec);
    end;
  end;
end;

function ResolvePortableDataPath(const SelectedPath: String): String;
var
  CandidateRoot: String;
  CandidateData: String;
begin
  Result := '';
  CandidateRoot := SelectedPath;
  if FileExists(AddBackslash(CandidateRoot) + '{#AppExeName}') then
  begin
    CandidateData := AddBackslash(CandidateRoot) + 'data';
    if FileExists(AddBackslash(CandidateData) + 'app.so') and
       DirExists(AddBackslash(CandidateData) + 'flutter_assets') then
    begin
      Result := CandidateData;
      Exit;
    end;
  end;

  CandidateRoot := AddBackslash(SelectedPath) + 'app';
  if FileExists(AddBackslash(CandidateRoot) + '{#AppExeName}') then
  begin
    CandidateData := AddBackslash(CandidateRoot) + 'data';
    if FileExists(AddBackslash(CandidateData) + 'app.so') and
       DirExists(AddBackslash(CandidateData) + 'flutter_assets') then
      Result := CandidateData;
  end;
end;

procedure InitializeWizard;
begin
  PortableDataChoicePage := CreateInputOptionPage(
    wpSelectDir,
    CustomMessage('PortableDataTitle'),
    CustomMessage('PortableDataDescription'),
    CustomMessage('PortableDataSubCaption'),
    False,
    False);
  PortableDataChoicePage.Add(CustomMessage('PortableDataOption'));
  PortableDataChoicePage.Values[0] := False;

  PortableDataPathPage := CreateInputDirPage(
    PortableDataChoicePage.ID,
    CustomMessage('PortableDataPathTitle'),
    CustomMessage('PortableDataPathDescription'),
    CustomMessage('PortableDataPathSubCaption'),
    False,
    '');
  PortableDataPathPage.Add('');
end;

function ShouldSkipPage(PageID: Integer): Boolean;
var
  HasInstalledData: Boolean;
begin
  HasInstalledData := DirectoryHasEntries(
    ExpandConstant('{localappdata}\pure_music'));
  Result := ((PageID = PortableDataChoicePage.ID) or
    (PageID = PortableDataPathPage.ID)) and HasInstalledData;
  if not Result and (PageID = PortableDataPathPage.ID) then
    Result := not PortableDataChoicePage.Values[0];
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if CurPageID = PortableDataChoicePage.ID then
  begin
    if not PortableDataChoicePage.Values[0] then
      PortableSourceData := '';
    Exit;
  end;

  if CurPageID <> PortableDataPathPage.ID then
    Exit;

  PortableSourceData := '';
  PortableSourceData := ResolvePortableDataPath(PortableDataPathPage.Values[0]);
  if PortableSourceData = '' then
  begin
    MsgBox(CustomMessage('PortableDataInvalid'), mbError, MB_OK);
    Result := False;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  PowerShellPath: String;
  ScriptPath: String;
  Params: String;
  ResultCode: Integer;
begin
  if (CurStep = ssInstall) and (PortableSourceData <> '') then
    ExtractTemporaryFile('import_portable_data.ps1');

  if (CurStep <> ssPostInstall) or (PortableSourceData = '') then
    Exit;

  WizardForm.StatusLabel.Caption := CustomMessage('PortableDataImporting');
  PowerShellPath := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
  ScriptPath := ExpandConstant('{tmp}\import_portable_data.ps1');
  Params := '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' +
    AddQuotes(ScriptPath) + ' -SourceData ' + AddQuotes(PortableSourceData) +
    ' -DestinationData ' + AddQuotes(ExpandConstant('{localappdata}\pure_music'));

  if (not Exec(PowerShellPath, Params, '', SW_HIDE, ewWaitUntilTerminated, ResultCode)) or
     (ResultCode <> 0) then
  begin
    Log(Format('便携版数据导入失败，退出代码：%d', [ResultCode]));
    MsgBox(CustomMessage('PortableDataImportFailed'), mbError, MB_OK);
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  UserDataPath: String;
begin
  if CurUninstallStep <> usPostUninstall then
    Exit;

  UserDataPath := ExpandConstant('{localappdata}\pure_music');
  if not DirExists(UserDataPath) then
    Exit;

  if SuppressibleMsgBox(
       CustomMessage('DeleteUserDataPrompt'),
       mbConfirmation,
       MB_YESNO or MB_DEFBUTTON2,
       IDNO) = IDYES then
  begin
    if not DelTree(UserDataPath, True, True, True) then
      SuppressibleMsgBox(
        FmtMessage(CustomMessage('DeleteUserDataFailed'), [UserDataPath]),
        mbError,
        MB_OK,
        IDOK);
  end;
end;
