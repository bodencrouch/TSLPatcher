unit UCLIActions;

interface
function RunCLI: integer;

implementation

uses Classes, SysUtils, IniFiles, UCLIOptions, UCLIConfig, UCLIManifest, UCLIGamePaths,
UPatcherPlatform, UTSLPatcher
{$IFDEF UNIX}, BaseUnix, Unix{$ENDIF}
{$IFDEF MSWINDOWS}, Windows{$ENDIF};

type
TProcessLock = class
  private
  FHandle: THandle;
  public
  constructor Create(const Root: string);
  destructor Destroy; override;
end;
TInstallLog = class
  Lines: TStringList;
  Level: integer;
  constructor Create;
  destructor Destroy; override;
  procedure Log(const Text: string; Severity: integer);
  procedure Save(const ModRoot: string);
end;
constructor TProcessLock.Create(const Root: string);

var Path: string;
begin
  inherited Create;
  FHandle := THandle(-1);
  Path := IncludeTrailingPathDelimiter(Root) + '.tslpatcher.lock';
  CheckNoLinks(Path);
  {$IFDEF UNIX}
  FHandle := fpOpen(PChar(Path), O_RDWR or O_CREAT, &600);
  if FHandle = THandle(-1) then RaiseLastOSError;
  if fpFlock(FHandle, LOCK_EX or LOCK_NB) <> 0 then
  begin
    fpClose(FHandle);
    FHandle := THandle(-1);
    raise Exception.Create('Another patcher is using ' + Root);
  end;
  {$ELSE}
  FHandle := CreateFile(PChar(Path), GENERIC_READ or GENERIC_WRITE, 0, nil, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  if FHandle = INVALID_HANDLE_VALUE then raise Exception.Create('Cannot lock patcher root: ' + Root);
  {$ENDIF}
end;
destructor TProcessLock.Destroy;
begin
  if FHandle <> THandle(-1) then
  begin
    {$IFDEF UNIX}
    fpClose(FHandle); {$ELSE}
    CloseHandle(FHandle); {$ENDIF}
  end;
  inherited;
end;
constructor TInstallLog.Create;
begin
  inherited;
  Lines := TStringList.Create;
end;
destructor TInstallLog.Destroy;
begin
  Lines.Free;
  inherited;
end;
procedure TInstallLog.Log(const Text: string; Severity: integer);

var Show: boolean;
begin
  Lines.Add(Text);
  Show := (Level >= 4) or ((Level >= 3) and (Severity <> LOG_LEVEL_VERBOSE)) or
  ((Level >= 2) and (Severity = LOG_LEVEL_ERROR)) or
  ((Level >= 1) and ((Severity = LOG_LEVEL_INFORMATION) or (Severity = LOG_LEVEL_NOTICE)));
  if Show then
  begin
    if Severity = LOG_LEVEL_ERROR then WriteLn(StdErr, Text)
    else WriteLn(Text);
  end;
end;
procedure TInstallLog.Save(const ModRoot: string);

var RTF: string;
begin
  DurableText(ManagedPath(ModRoot, 'installlog.txt'), Lines.Text);
  RTF := StringReplace(Lines.Text, '\', '\\', [rfReplaceAll]);
  RTF := StringReplace(RTF, '{', '\{', [rfReplaceAll]);
  RTF := StringReplace(RTF, '}', '\}', [rfReplaceAll]);
  RTF := StringReplace(RTF, #13, '', [rfReplaceAll]);
  RTF := StringReplace(RTF, #10, '\par' + #10, [rfReplaceAll]);
  DurableText(ManagedPath(ModRoot, 'installlog.rtf'), '{\rtf1\ansi ' + RTF + '}');
end;
procedure CollectTree(const Root, Relative: string; Files: TStrings);

var Search: TSearchRec;
Pattern, Child: string;
begin
  if Relative = '' then Pattern := IncludeTrailingPathDelimiter(Root)
  else Pattern := IncludeTrailingPathDelimiter(ManagedPath(Root, Relative));
  if SysUtils.FindFirst(Pattern + '*', faAnyFile, Search) <> 0 then Exit;
  try
    repeat
      if (Search.Name = '.') or (Search.Name = '..') then Continue;
      Child := Relative + Search.Name;
      CheckNoLinks(Pattern + Search.Name);
      if (Search.Attr and faDirectory) <> 0 then CollectTree(Root, Child + PathDelim, Files)
      else Files.Add(Child);
    until SysUtils.FindNext(Search) <> 0;
  finally
    SysUtils.FindClose(Search);
  end;
end;
function IsTimestamp(const Name: string): boolean;

var Index: integer;
begin
  Result := False;
  if Length(Name) <> 19 then Exit;
  for Index := 1 to 19 do
  begin
    case Index of
      5,8: if Name[Index] <> '-' then Exit;
      11: if Name[Index] <> '_' then Exit;
      14,17: if Name[Index] <> '.' then Exit;
      else if not (Name[Index] In ['0'..'9']) then Exit;
    end;
  end;
  Result := True;
end;
procedure RestoreLegacy(Session: TModSession; const BackupRoot, GameRoot: string);

var Search: TSearchRec;
Generations, Files, Sources, Targets, Removals, ConfigTargets: TStringList;
Directory, Source, Target, Relative, RootPrefix: string;
Index, Candidate, Matches: integer;
Timestamped: boolean;
begin
  Generations := TStringList.Create;
  Files := TStringList.Create;
  Sources := TStringList.Create;
  Targets := TStringList.Create;
  Removals := TStringList.Create;
  ConfigTargets := TStringList.Create;
  try
    if SysUtils.FindFirst(IncludeTrailingPathDelimiter(BackupRoot) + '*', faDirectory, Search) = 0 then
    begin
      repeat
        if ((Search.Attr and faDirectory) <> 0) and IsTimestamp(Search.Name) then Generations.Add(Search.Name);
      until SysUtils.FindNext(Search) <> 0;
      SysUtils.FindClose(Search);
    end;
    Generations.Sort;
    Directory := BackupRoot;
    Timestamped := False;
    for Index := Generations.Count-1 downto 0 do
    begin
      Directory := ManagedPath(BackupRoot, Generations[Index]);
      Files.Clear;
      CollectTree(Directory, '', Files);
      if Files.Count > 0 then
      begin
        Timestamped := True;
        Break;
      end;
    end;
    if not Timestamped then
    begin
      Directory := BackupRoot;
      Files.Clear;
      CollectTree(Directory, '', Files);
    end;
    if Files.Count = 0 then raise Exception.Create('Backup contains no restorable files');
    if not Timestamped then
    begin
      Session.Load;
      Session.Validate(GameRoot, False, ConfigTargets);
      ConfigTargets.Add(ManagedPath(GameRoot, 'dialog.tlk'));
      ConfigTargets.Add(ManagedPath(GameRoot, 'dialogf.tlk'));
    end;
    RootPrefix := IncludeTrailingPathDelimiter(NativePath(GameRoot));
    for Index := 0 to Files.Count-1 do
    begin
      Relative := Files[Index];
      Source := ManagedPath(Directory, Relative);
      if SameText(Relative, 'remove these files.txt') and Timestamped then
      begin
        Removals.LoadFromFile(Source);
        Continue;
      end;
      if Timestamped then Target := ManagedPath(GameRoot, Relative)
      else
      begin
        if Pos(PathDelim, Relative) > 0 then raise Exception.Create('Unknown legacy backup layout: ' + Relative);
        Target := '';
        Matches := 0;
        for Candidate := 0 to ConfigTargets.Count-1 do
        if SameText(ExtractFileName(ConfigTargets[Candidate]), Relative) and (Target <> ConfigTargets[ Candidate]) then
        begin
          Target := ConfigTargets[Candidate];
          Inc(Matches);
        end;
        if Matches <> 1 then raise Exception.Create('Ambiguous legacy backup destination: ' + Relative);
      end;
      CheckNoLinks(Target);
      if SysUtils.DirectoryExists(Target) then
        raise Exception.Create('Expected a file: ' + Target);
      Sources.Add(Source);
      Targets.Add(Target);
    end;
    for Index := 0 to Removals.Count-1 do
    begin
      Target := Trim(Removals[Index]);
      if Target = '' then Continue;
      Target := NativePath(Target);
      if Copy(Target,1,Length(RootPrefix)) <> RootPrefix then raise Exception.Create('Removal path outside game root: ' + Removals[Index]);
      Target := ManagedPath(GameRoot, Copy(Target, Length(RootPrefix)+1, MaxInt));
      if Targets.IndexOf(Target) >= 0 then raise Exception.Create('Conflicting restore and remove entries: ' + Target);
      if SysUtils.DirectoryExists(Target) then
        raise Exception.Create('Expected a file: ' + Target);
      Removals[Index] := Target;
    end;
    for Index := 0 to Sources.Count-1 do
    RawCopy(Sources[Index], Targets[Index]);
    for Index := 0 to Removals.Count-1 do
    begin
      Target := Removals[Index];
      if (Target <> '') and SysUtils.FileExists(Target) and not SysUtils.DeleteFile(Target) then raise
      Exception.Create('Cannot remove ' + Target);
    end;
    WriteLn('Restored legacy backup ', Directory, '; backup retained.');
  finally
    ConfigTargets.Free;
    Removals.Free;
    Targets.Free;
    Sources.Free;
    Files.Free;
    Generations.Free;
  end;
end;
function InstallMod(Session: TModSession; const Game: string; LogLevel: integer): integer;

var Manifest: TInstallManifest;
Engine: TTSLPatcher;
Log: TInstallLog;
Outcome: TPatcherResult;
begin
  Manifest := nil;
  Engine := nil;
  Log := TInstallLog.Create;
  try
    Log.Level := LogLevel;
    if Log.Level < 0 then Log.Level := Session.Config.ReadInteger('Settings', 'LogLevel', 3);
    Manifest := TInstallManifest.Create(Game, ManagedPath(Session.ModRoot, 'backup'), Session.DataRoot);
    WriteLn('Backup generation: ', Manifest.Directory);
    Engine := TTSLPatcher.CreateHeadless(Session.DataPath, ExtractFileName(Session.IniPath), Game, Manifest.Directory + PathDelim + 'legacy');
    Engine.CompilerPath := Session.Compiler;
    Engine.BeforeWrite := Manifest.Capture;
    Engine.LogCallback := Log.Log;
    try
      Outcome := Engine.RunPatchOperation;
      Manifest.SetState('complete');
      WriteLn('Installation complete: ', Outcome.Warnings, ' warnings, ', Outcome.Errors, ' errors.');
      Result := 0;
      if Outcome.Errors > 0 then Result := 8;
    except
      on Error: Exception do
      begin
        Log.Log('Installation failed: ' + Error.Message, LOG_LEVEL_ERROR);
        WriteLn(StdErr, 'Installation failed: ', Error.Message);
        Manifest.SetState('partial');
        Result := 7;
      end;
    end;
  finally
    Engine.Free;
    try
      Log.Save(Session.ModRoot);
    finally
      Log.Free;
      Manifest.Free;
    end;
  end;
end;
function ExecuteCLI: integer;

var Options: TCLIOptions;
Session: TModSession;
Direct: boolean;
Actions, Index: integer;
Base, Game, Answer, Confirmation, Backup: string;
GameLock, ModLock: TProcessLock;
Keys: TStringList;
begin
  ParseOptions(Options);
  if Options.Help then
  begin
    PrintHelp;
    Result := 0;
    Exit;
  end;
  if Options.Version then
  begin
    WriteLn('TSLPatcher native CLI 1.0');
    Result := 0;
    Exit;
  end;
  Actions := Ord(Options.Install) + Ord(Options.Uninstall) + Ord(Options.Validate);
  Direct := (Actions > 0) or (Options.ModPath <> '') or Options.HasIndex;
  if Direct and (Options.ModPath = '') then raise ECLIError.CreateCode(2, '--tslpatchdata is required');
  Base := Options.ModPath;
  if not Direct then Base := ExtractFileDir(ExpandFileName(ParamStr(0)))
  else
  begin
    Options.IniName := 'changes.ini';
    Options.InfoName := 'info.rtf';
  end;
  Session := TModSession.Create(Base, Options.IniName, Options.InfoName);
  try
    if not Direct and Options.List then
    begin
      for Index := 0 to Session.Names.Count-1 do
      WriteLn(Index, ': ', Session.Names[Index]);
      Result := 0;
      Exit;
    end;
    Index := Options.Index;
    if not Direct and Assigned(Session.Namespaces) then
    begin
      if Options.Namespace <> '' then
      begin
        if not TryStrToInt(Options.Namespace, Index) or (Index < 0) or (Index >= Session.Names.Count) then
        begin
          Index := Session.Names.IndexOf(Options.Namespace);
          if Index < 0 then raise ECLIError.CreateCode(2, 'Unknown namespace: ' + Options.Namespace);
        end;
      end
      else if not Options.Yes then
      begin
        for Index := 0 to Session.Names.Count-1 do
        WriteLn(Index, ': ', Session.Names[Index]);
        write('Namespace index: ');
        ReadLn(Answer);
        if not TryStrToInt(Answer, Index) then raise ECLIError.CreateCode(2, 'Invalid namespace index');
      end;
    end;
    try
      Session.Select(Index);
    except
      on Error: ECLIError do
      begin
        if not Direct then Error.Code := 2;
        raise;
      end;
    end;
    if Direct and (Actions <> 1) then raise ECLIError.CreateCode(2, 'Exactly one of --install, --uninstall or --validate is required');
    if not Direct and Options.Info then
    begin
      WriteLn(PlainRTF(Session.InfoPath));
      Result := 0;
      Exit;
    end;
    if not Direct and Options.Summary then
    begin
      try
        Session.Load;
        Keys := TStringList.Create;
        try
          Session.Config.ReadSections(Keys);
          WriteLn(Session.IniPath, ': ', Keys.Count, ' sections');
          write(Keys.Text);
        finally
          Keys.Free;
        end;
      except
        on Error: Exception do WriteLn('Cannot load summary: ', Error.Message);
      end;
      Result := 0;
      Exit;
    end;
    if not Direct then
    begin
      try
        Session.Load;
      except
        on Error: Exception do raise ECLIError.CreateCode(2, Error.Message);
      end;
      Confirmation := Session.Config.ReadString('Settings', 'ConfirmMessage', '');
      if not Options.Yes and (Confirmation <> '') and (Confirmation <> 'N/A') then
      begin
        WriteLn(Confirmation);
        write('Continue? [y/N] ');
        ReadLn(Answer);
        Answer := Trim(Answer);
        if not SameText(Answer, 'y') and not SameText(Answer, 'yes') then
        begin
          Result := 1;
          Exit;
        end;
      end;
    end;
    Game := Options.GameDir;
    if Direct then
    begin
      if Game = '' then Game := Options.Game;
    end
    else if Options.Game <> '' then Game := Options.Game;
    if (Game <> '') and not SysUtils.DirectoryExists(NativePath(Game)) then
    begin
      if Direct then raise ECLIError.CreateCode(2, 'Game directory does not exist: ' + Game);
      WriteLn(StdErr, 'Game directory does not exist: ', Game);
      Game := '';
    end;
    if (Game = '') and not Direct then Game := DetectGame(Session.Config);
    if (Game = '') and not Options.Validate then
    begin
      if Direct then raise ECLIError.CreateCode(2, 'A game directory is required');
      if not Options.Yes then
      begin
        write('Game directory: ');
        ReadLn(Game);
      end;
      if (Game = '') or not SysUtils.DirectoryExists(NativePath(Game)) then
      begin
        Result := 1;
        Exit;
      end;
    end;
    if Game <> '' then
    begin
      Game := CanonicalPath(Game);
    end;
    if Options.Validate then
    begin
      Session.Load;
      Session.Validate(Game, True, nil);
      WriteLn('Validation passed; game files were not modified.');
      Result := 0;
      Exit;
    end;
    if not Options.Uninstall then
    begin
      try
        Session.Load;
        // Source absence remains an engine error; static unsafe configuration blocks before writes.
        Session.Validate(Game, False, nil);
      except
        on Error: Exception do
        begin
          if Direct then raise ECLIError.CreateCode(6, Error.Message)
          else raise ECLIError.CreateCode(2, Error.Message);
        end;
      end;
    end;
    GameLock := nil;
    ModLock := nil;
    try
      try
        GameLock := TProcessLock.Create(Game);
        if Game <> Session.ModRoot then ModLock := TProcessLock.Create(Session.ModRoot);
        if Options.Uninstall then
        begin
          Backup := ManagedPath(Session.ModRoot, 'backup');
          if not SysUtils.DirectoryExists(Backup) then raise Exception.Create('Backup directory not found');
          if not RestoreManifest(Backup, Game) then RestoreLegacy(Session, Backup, Game);
          Result := 0;
        end
        else Result := InstallMod(Session, Game, Options.LogLevel);
        if not Direct and (Result <> 0) then Result := 1;
      finally
        ModLock.Free;
        GameLock.Free;
      end;
    except
      on Error: Exception do begin
        if not Direct then raise ECLIError.CreateCode(1, Error.Message);
        raise;
      end;
    end;
  finally
    Session.Free;
  end;
end;
function RunCLI: integer;
begin
  try
    Result := ExecuteCLI;
  except
    on Error: ECLIError do
    begin
      WriteLn(StdErr, Error.Message);
      Result := Error.Code;
    end;
    on Error: Exception do
    begin
      WriteLn(StdErr, Error.Message);
      Result := 7;
    end;
  end;
end;
end.
