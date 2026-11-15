unit UCLIManifest;

interface

uses Classes, SysUtils;

type
TInstallManifest = class
  private
  FRoot, FBackup, FDirectory, FSourceRoot: string;
  FEntries: TStringList;
  FCaptureFailed: Boolean;
  public
  constructor Create(const GameRoot, BackupRoot, SourceRoot: string);
  destructor Destroy; override;
  procedure Capture(const Destination: string);
  procedure SetState(const State: string);
  property Directory: string read FDirectory;
end;
function CanonicalPath(const Path: string): string;
function SafePath(const Root, Relative: string; AllowRoot: boolean = False): string;
function ManagedPath(const Root, Relative: string): string;
procedure CheckNoLinks(const Path: string);
procedure RawCopy(const Source, Destination: string);
procedure DurableText(const Path, Value: string);
function RestoreManifest(const BackupRoot, GameRoot: string): boolean;
function HexEncode(const Value: string): string;
function HexDecode(const Value: string): string;

implementation

uses UPatcherPlatform
{$IFDEF UNIX}, BaseUnix, Unix{$ENDIF}
{$IFDEF MSWINDOWS}, Windows{$ENDIF};
{$IFDEF MSWINDOWS}
const
  // Win32 MoveFileEx flag supplied locally for FPC 3.2.2 Windows headers.
  CLI_MOVEFILE_WRITE_THROUGH = $00000008;

function GetFinalPathNameByHandleA(FileHandle: THandle; FilePath: PChar; BufferSize, Flags: DWORD): DWORD;
stdcall;
external 'kernel32.dll';
{$ENDIF}
function CanonicalPath(const Path: string): string;

var Existing: string;
{$IFDEF UNIX}
Link, Prefix, Remaining, Component: string;
Separator, Hops: integer;
Info: Stat;
{$ENDIF}
{$IFDEF MSWINDOWS}
Tail, Parent: string;
Handle: THandle;
Buffer: array[0..32767] of Char;
Size: DWORD;
{$ENDIF}
begin
  Existing := NativePath(Path);
  {$IFDEF UNIX}
  Remaining := Existing;
  Prefix := PathDelim;
  Hops := 0;
  while Remaining <> '' do
  begin
    if Remaining[1] = PathDelim then Delete(Remaining, 1, 1);
    Separator := Pos(PathDelim, Remaining);
    if Separator = 0 then
    begin
      Component := Remaining;
      Remaining := '';
    end
    else
    begin
      Component := Copy(Remaining, 1, Separator-1);
      Delete(Remaining, 1, Separator);
    end;
    Prefix := IncludeTrailingPathDelimiter(Prefix) + Component;
    if (fpLStat(PChar(Prefix), Info) = 0) and FPS_ISLNK(Info.st_mode) then
    begin
      Inc(Hops);
      if Hops > 40 then raise Exception.Create('Too many symbolic links: ' + Path);
      Link := fpReadLink(Prefix);
      if Link = '' then raise Exception.Create('Cannot resolve symbolic link: ' + Prefix);
      if Link[1] <> PathDelim then Link := ExtractFileDir(Prefix) + PathDelim + Link;
      Remaining := ExpandFileName(Link) + PathDelim + Remaining;
      Prefix := PathDelim;
    end;
  end;
  Result := NativePath(Prefix);
  {$ELSE}
  Tail := '';
  while not SysUtils.FileExists(Existing) and not SysUtils.DirectoryExists(Existing) do
  begin
    Parent := ExtractFileDir(Existing);
    if Parent = Existing then raise Exception.Create('Cannot resolve path: ' + Path);
    Tail := PathDelim + ExtractFileName(Existing) + Tail;
    Existing := Parent;
  end;
  Handle := CreateFile(PChar(Existing), 0, FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, 0);
  if Handle = INVALID_HANDLE_VALUE then RaiseLastOSError;
  try
    Size := GetFinalPathNameByHandleA(Handle, @Buffer[0], Length(Buffer), 0);
    if (Size = 0) or (Size >= Length(Buffer)) then RaiseLastOSError;
    SetString(Result, Buffer, Size);
    if Copy(Result, 1, 8) = '\\?\UNC\' then Result := '\\' + Copy(Result, 9, MaxInt)
    else if Copy(Result, 1, 4) = '\\?\' then Delete(Result, 1, 4);
    Result := NativePath(Result + Tail);
  finally
    CloseHandle(Handle);
  end;
  {$ENDIF}
end;
function HexEncode(const Value: string): string;

var EntryIndex: integer;
begin
  Result := '';
  for EntryIndex := 1 to Length(Value) do
  Result := Result + IntToHex(Ord(Value[EntryIndex]), 2);
end;
function HexDecode(const Value: string): string;

var EntryIndex, Number: integer;
begin
  if Odd(Length(Value)) then raise Exception.Create('Invalid manifest encoding');
  Result := '';
  for EntryIndex := 1 to Length(Value) div 2 do
  begin
    if not TryStrToInt('$' + Copy(Value, EntryIndex*2-1, 2), Number) then raise Exception.Create('Invalid manifest encoding');
    if Number = 0 then raise Exception.Create('NUL in manifest path');
    Result := Result + Chr(Number);
  end;
end;
procedure CheckNoLinks(const Path: string);
begin
  UPatcherPlatform.CheckNoLinks(Path);
end;
function SafePath(const Root, Relative: string; AllowRoot: boolean): string;

var RootPrefix, EntryText: string;
begin
  RootPrefix := IncludeTrailingPathDelimiter(CanonicalPath(Root));
  EntryText := StringReplace(Relative, '\', PathDelim, [rfReplaceAll]);
  if (EntryText = '') or (EntryText[1] = PathDelim) or (Pos(':', EntryText) > 0) or (Pos(#0, EntryText) > 0)
  then
  raise Exception.Create('Expected a relative path: ' + Relative);
  Result := CanonicalPath(RootPrefix + EntryText);
  if AllowRoot and (Result = ExcludeTrailingPathDelimiter(RootPrefix)) then Exit;
  if Copy(Result, 1, Length(RootPrefix)) <> RootPrefix then raise Exception.Create('Path escapes root: ' + Relative);
end;
// Roots are canonicalized at selection. Preserve descendant lexical identity
// so a replacement link cannot redirect a journaled write or deletion.
function ManagedPath(const Root, Relative: string): string;
var RootPrefix, EntryText: string;
begin
  RootPrefix := IncludeTrailingPathDelimiter(Root);
  EntryText := StringReplace(Relative, '\', PathDelim, [rfReplaceAll]);
  if (EntryText = '') or (EntryText[1] = PathDelim) or
    (Pos(':', EntryText) > 0) or (Pos(#0, EntryText) > 0) then
    raise Exception.Create('Expected a relative path: ' + Relative);
  Result := NativePath(RootPrefix + EntryText);
  if Copy(Result, 1, Length(RootPrefix)) <> RootPrefix then
    raise Exception.Create('Path escapes root: ' + Relative);
  CheckNoLinks(Result);
end;

procedure Flush(Stream: Classes.TFileStream);
begin
  {$IFDEF UNIX}
  if fpFsync(Stream.Handle) <> 0 then RaiseLastOSError;
  {$ELSE}
  if not FlushFileBuffers(Stream.Handle) then RaiseLastOSError;
  {$ENDIF}
end;
procedure SyncDirectory(const Directory: string);
{$IFDEF UNIX}

var Handle: integer;
{$ENDIF}
begin
  {$IFDEF UNIX}
  Handle := fpOpen(PChar(Directory), O_RDONLY);
  if Handle < 0 then RaiseLastOSError;
  try
    if fpFsync(Handle) <> 0 then RaiseLastOSError;
  finally
    fpClose(Handle);
  end;
  {$ENDIF}
end;
procedure DurableDirectories(const Directory: string);
var Parent: string;
begin
  CheckNoLinks(Directory);
  if SysUtils.DirectoryExists(Directory) then Exit;
  Parent := ExtractFileDir(Directory);
  if (Parent = '') or (Parent = Directory) then
    raise Exception.Create('Cannot create directory: ' + Directory);
  DurableDirectories(Parent);
  if not SysUtils.CreateDir(Directory) then
    raise Exception.Create('Cannot create directory: ' + Directory);
  // Publish each new child in its parent before any managed file write.
  SyncDirectory(Parent);
end;

function GenerationNumber(const Name: string): integer;
var Index: integer;
begin
  Result := 0;
  if (Length(Name) <> 12) or (Copy(Name, 1, 4) <> 'cli-') then Exit;
  for Index := 5 to 12 do
    if not (Name[Index] in ['0'..'9']) then Exit;
  Result := StrToInt(Copy(Name, 5, 8));
end;

function LatestGeneration(const BackupRoot: string): integer;
var Search: TSearchRec; Number: integer;
begin
  Result := 0;
  if SysUtils.FindFirst(IncludeTrailingPathDelimiter(BackupRoot) + 'cli-*',
    faDirectory, Search) <> 0 then Exit;
  try
    repeat
      if (Search.Attr and faDirectory) <> 0 then
      begin
        Number := GenerationNumber(Search.Name);
        if Number > Result then Result := Number;
      end;
    until SysUtils.FindNext(Search) <> 0;
  finally
    SysUtils.FindClose(Search);
  end;
end;

function GenerationName(Number: integer): string;
begin
  Result := Format('cli-%8.8d', [Number]);
end;

procedure DurableText(const Path, Value: string);

var Stream: Classes.TFileStream;
begin
  CheckNoLinks(Path);
  Stream := Classes.TFileStream.Create(Path, fmCreate);
  try
    if Value <> '' then Stream.WriteBuffer(Value[1], Length(Value));
    Flush(Stream);
  finally
    Stream.Free;
  end;
  SyncDirectory(ExtractFileDir(Path));
end;
procedure RawCopy(const Source, Destination: string);

var SourceStream, DestinationStream: Classes.TFileStream;
begin
  CheckNoLinks(Source);
  CheckNoLinks(Destination);
  DurableDirectories(ExtractFileDir(Destination));
  SourceStream := Classes.TFileStream.Create(Source, fmOpenRead or fmShareDenyWrite);
  try
    DestinationStream := Classes.TFileStream.Create(Destination, fmCreate);
    try
      DestinationStream.CopyFrom(SourceStream, 0);
      Flush(DestinationStream);
    finally
      DestinationStream.Free;
    end;
  finally
    SourceStream.Free;
  end;
  SyncDirectory(ExtractFileDir(Destination));
end;
constructor TInstallManifest.Create(const GameRoot, BackupRoot, SourceRoot: string);

var Number: integer;
begin
  inherited Create;
  FEntries := TStringList.Create;
  FRoot := NativePath(GameRoot);
  FSourceRoot := CanonicalPath(SourceRoot);
  FBackup := NativePath(BackupRoot);
  CheckNoLinks(FRoot);
  CheckNoLinks(FBackup);
  DurableDirectories(FBackup);
  SyncDirectory(ExtractFileDir(FBackup));
  Number := LatestGeneration(FBackup);
  if Number = 99999999 then raise Exception.Create('Backup generation limit reached');
  FDirectory := ManagedPath(FBackup, GenerationName(Number + 1));
  if not SysUtils.CreateDir(FDirectory) then raise Exception.Create('Cannot create backup generation');
  SyncDirectory(FBackup);
  DurableText(FDirectory + PathDelim + 'game-root', HexEncode(FRoot));
  DurableText(FDirectory + PathDelim + 'manifest', 'TSLPATCHER-MANIFEST-1' + #10);
  SetState('active');
end;
destructor TInstallManifest.Destroy;
begin
  FEntries.Free;
  inherited;
end;
procedure TInstallManifest.SetState(const State: string);
begin
  DurableText(FDirectory + PathDelim + 'state.new', State);
  {$IFDEF MSWINDOWS}
  if not MoveFileEx(PChar(FDirectory + PathDelim + 'state.new'), PChar(FDirectory + PathDelim + 'state'), MOVEFILE_REPLACE_EXISTING or CLI_MOVEFILE_WRITE_THROUGH) then RaiseLastOSError;
  {$ELSE}
  if not SysUtils.RenameFile(FDirectory + PathDelim + 'state.new', FDirectory + PathDelim + 'state') then
  RaiseLastOSError;
  {$ENDIF}
  SyncDirectory(FDirectory);
end;
procedure TInstallManifest.Capture(const Destination: string);

var CurrentPath, Rel, Line, Key: string;
Stream: Classes.TFileStream;
Exists: boolean;
begin
  CurrentPath := NativePath(Destination);
  // Engine-owned source recovery remains available after a game capture failure.
  if (Copy(CurrentPath, 1, Length(IncludeTrailingPathDelimiter(FSourceRoot))) =
    IncludeTrailingPathDelimiter(FSourceRoot)) or
    (Copy(CurrentPath, 1, Length(IncludeTrailingPathDelimiter(FBackup))) =
    IncludeTrailingPathDelimiter(FBackup)) then
  begin
    CheckNoLinks(CurrentPath);
    Exit;
  end;
  if FCaptureFailed then raise Exception.Create('An earlier before-image capture failed; refusing further game writes');
  try
    CheckNoLinks(CurrentPath);
    Rel := Copy(CurrentPath, Length(IncludeTrailingPathDelimiter(FRoot))+1, MaxInt);
    if ManagedPath(FRoot, Rel) <> CurrentPath then raise Exception.Create('Write outside game root: ' + CurrentPath);
    Key := HexEncode(Rel);
    if FEntries.IndexOf(Key) >= 0 then Exit;
    Exists := SysUtils.FileExists(CurrentPath);
    if SysUtils.DirectoryExists(CurrentPath) then raise Exception.Create('Expected a file: ' + CurrentPath);
    if Exists then RawCopy(CurrentPath, FDirectory + PathDelim + IntToStr(FEntries.Count) + '.bin');
    Line := Key + '|' + IntToStr(Ord(Exists)) + #10;
    Stream := Classes.TFileStream.Create(FDirectory + PathDelim + 'manifest', fmOpenReadWrite or fmShareExclusive);
    try
      Stream.Seek(0, soFromEnd);
      Stream.WriteBuffer(Line[1], Length(Line));
      Flush(Stream);
    finally
      Stream.Free;
    end;
    FEntries.Add(Key);
  except
    FCaptureFailed := True;
    raise;
  end;
end;
function ReadText(const Path: string): string;

var L: TStringList;
begin
  CheckNoLinks(Path);
  L := TStringList.Create;
  try
    L.LoadFromFile(Path);
    Result := Trim(L.Text);
  finally
    L.Free;
  end;
end;
procedure ReadJournal(const Path: string; Lines: TStrings);
var Stream: Classes.TFileStream; Bytes: string;
begin
  CheckNoLinks(Path);
  Stream := Classes.TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite);
  try
    if Stream.Size > MaxInt then raise Exception.Create('Manifest is too large');
    SetLength(Bytes, Stream.Size);
    if Length(Bytes) > 0 then Stream.ReadBuffer(Bytes[1], Length(Bytes));
  finally Stream.Free; end;
  // An interrupted append cannot authorize a write: Capture returns only after
  // the complete newline-terminated record has been flushed successfully.
  if (Bytes <> '') and (Bytes[Length(Bytes)] <> #10) then begin
    while (Bytes <> '') and (Bytes[Length(Bytes)] <> #10) do Delete(Bytes, Length(Bytes), 1);
    WriteLn('Ignoring an incomplete final manifest record.');
  end;
  Lines.Text := Bytes;
end;
function RestoreManifest(const BackupRoot, GameRoot: string): boolean;

var Lines, Targets: TStringList;
Generation, CurrentPath, EntryText, Root, Snapshot: string;
EntryIndex, Separator, Number: integer;
begin
  Result := False;
  Lines := TStringList.Create;
  Targets := TStringList.Create;
  try
    CheckNoLinks(BackupRoot);
    Root := NativePath(GameRoot);
    CheckNoLinks(Root);
    Number := LatestGeneration(BackupRoot);
    if Number = 0 then Exit;
    // Retained backups are reapplied on retry, including after successful restoration.
    Generation := ManagedPath(BackupRoot, GenerationName(Number));
    CheckNoLinks(Generation + PathDelim + 'state');
    if not SysUtils.FileExists(Generation + PathDelim + 'state') then
      raise Exception.Create('Missing latest CLI backup generation state');
    Result := True;
    if HexDecode(ReadText(Generation + PathDelim + 'game-root')) <> Root then raise Exception.Create('Backup belongs to a different game root');
    CheckNoLinks(Generation + PathDelim + 'manifest');
    ReadJournal(Generation + PathDelim + 'manifest', Lines);
    if (Lines.Count = 0) or (Lines[0] <> 'TSLPATCHER-MANIFEST-1') then raise Exception.Create('Unknown manifest format');
    // Preflight every entry and before-image before touching the game.
    for EntryIndex := 1 to Lines.Count-1 do
    begin
      EntryText := Lines[EntryIndex];
      Separator := Pos('|', EntryText);
      if (Separator = 0) or not ((Copy(EntryText, Separator+1, MaxInt) = '0') or (Copy(EntryText, Separator+ 1, MaxInt) = '1')) then raise Exception.Create('Invalid manifest entry');
      CurrentPath := ManagedPath(Root, HexDecode(Copy(EntryText,1,Separator-1)));
      if SysUtils.DirectoryExists(CurrentPath) then
        raise Exception.Create('Expected a file: ' + CurrentPath);
      Targets.Add(CurrentPath);
      if EntryText[Length(EntryText)] = '1' then
      begin
        Snapshot := ManagedPath(Generation, IntToStr(EntryIndex-1) + '.bin');
        if not SysUtils.FileExists(Snapshot) then raise Exception.Create('Missing before-image: ' + Snapshot);
      end;
    end;
    for EntryIndex := Lines.Count-1 downto 1 do
    begin
      CurrentPath := Targets[EntryIndex-1];
      if Lines[EntryIndex][Length(Lines[EntryIndex])] = '1' then RawCopy(ManagedPath(Generation, IntToStr(EntryIndex-1) + '.bin'), CurrentPath)
      else if SysUtils.FileExists(CurrentPath) and not SysUtils.DeleteFile(CurrentPath) then raise Exception
      .Create('Cannot remove ' + CurrentPath);
    end;
    DurableText(Generation + PathDelim + 'state', 'restored');
    WriteLn('Restored backup ' + Generation + '.');
  finally
    Targets.Free;
    Lines.Free;
  end;
end;
end.
