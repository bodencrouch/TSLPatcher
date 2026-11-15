unit UPatcherPlatform;

{ Native boundaries for the original engine. No GUI emulation is used. }
interface

uses Classes, SysUtils;

type
  TPatcherBeforeWrite = procedure(const Destination: string) of object;
  TFileStream = class(Classes.TFileStream)
    constructor Create(const FileName: string; Mode: Word);
  end;

var
  BeforeWrite: TPatcherBeforeWrite;
  WriteRoot: string;

function NativePath(const Value: string): string;
procedure NotifyWrite(const FileName: string);
function FileExists(const FileName: string): Boolean;
function DirectoryExists(const Directory: string): Boolean;
function ForceDirectories(const Directory: string): Boolean;
function RemoveDir(const Directory: string): Boolean;
function DeleteFile(const FileName: string): Boolean;
function RenameFile(const OldName, NewName: string): Boolean;
function FindFirst(const Path: string; Attr: LongInt; out Search: TSearchRec): LongInt;
function RunNativeCommand(const Executable, Parameters, WorkingDirectory: string): string;
function RunNativeCompiler(const Executable, Flags, WorkingDirectory, SourceFile, OutputFile: string): string;

implementation

uses Process;

function NativePath(const Value: string): string;
var Parts: TStringList; Current, Part, Match: string; Separator: Integer; I, Count: Integer; SR: TSearchRec;
begin
  Result := StringReplace(Value, '\', PathDelim, [rfReplaceAll]);
  if Result = '' then Exit;
  Result := ExpandFileName(Result);
  { Resolve existing components without changing the spelling of new components.
    Ambiguous case aliases fail instead of overwriting an arbitrary file. }
  Parts := TStringList.Create;
  try
    Current := ExtractFileDrive(Result);
    Delete(Result, 1, Length(Current));
    // Path components are literal filenames, never quoted command-line syntax.
    while Result <> '' do begin
      Separator := Pos(PathDelim, Result);
      if Separator = 0 then begin Parts.Add(Result); Break; end;
      if Separator > 1 then Parts.Add(Copy(Result, 1, Separator - 1));
      Delete(Result, 1, Separator);
    end;
    Current := Current + PathDelim;
    for I := 0 to Parts.Count - 1 do begin
      Part := Parts[I];
      if not SysUtils.FileExists(Current + Part) and not SysUtils.DirectoryExists(Current + Part) then begin
        Match := ''; Count := 0;
        if SysUtils.FindFirst(Current + '*', faAnyFile, SR) = 0 then begin
          repeat
            if SameText(SR.Name, Part) then begin Match := SR.Name; Inc(Count); end;
          until SysUtils.FindNext(SR) <> 0;
          SysUtils.FindClose(SR);
        end;
        if Count > 1 then raise Exception.Create('Ambiguous case-insensitive path: ' + Current + Part);
        if Count = 1 then Part := Match;
      end;
      Current := IncludeTrailingPathDelimiter(Current + Part);
    end;
    Result := ExcludeTrailingPathDelimiter(Current);
    if Result = '' then Result := PathDelim;
  finally Parts.Free; end;
end;

procedure NotifyWrite(const FileName: string);
var Path, Root: string;
begin
  if not Assigned(BeforeWrite) or (WriteRoot = '') then Exit;
  Path := NativePath(FileName);
  Root := IncludeTrailingPathDelimiter(NativePath(WriteRoot));
  if Copy(Path, 1, Length(Root)) = Root then BeforeWrite(Path);
end;

constructor TFileStream.Create(const FileName: string; Mode: Word);
var Path: string;
begin
  Path := NativePath(FileName);
  if ((Mode and fmCreate) = fmCreate) or ((Mode and 3) <> fmOpenRead) then NotifyWrite(Path);
  inherited Create(Path, Mode);
end;

function FileExists(const FileName: string): Boolean;
begin Result := SysUtils.FileExists(NativePath(FileName)); end;
function DirectoryExists(const Directory: string): Boolean;
begin Result := SysUtils.DirectoryExists(NativePath(Directory)); end;
function ForceDirectories(const Directory: string): Boolean;
begin Result := SysUtils.ForceDirectories(NativePath(Directory)); end;
function RemoveDir(const Directory: string): Boolean;
begin Result := SysUtils.RemoveDir(NativePath(Directory)); end;
function DeleteFile(const FileName: string): Boolean;
begin NotifyWrite(FileName); Result := SysUtils.DeleteFile(NativePath(FileName)); end;
function RenameFile(const OldName, NewName: string): Boolean;
begin
  NotifyWrite(OldName); NotifyWrite(NewName);
  Result := SysUtils.RenameFile(NativePath(OldName), NativePath(NewName));
end;
function FindFirst(const Path: string; Attr: LongInt; out Search: TSearchRec): LongInt;
begin Result := SysUtils.FindFirst(StringReplace(NativePath(Path), '*.*', '*', []), Attr, Search); end;

function RunNativeProcess(const Executable, Parameters, WorkingDirectory: string;
  const Arguments: array of string): string;
var Child: TProcess; I, N: Integer; Quote: Char; TokenStarted: Boolean; Token, Chunk: string; Buffer: array[0..8191] of Char;
begin
  Child := TProcess.Create(nil);
  try
    Child.Executable := NativePath(Executable);
    Child.CurrentDirectory := NativePath(WorkingDirectory);
    { Parse quotes as argument grouping only. No shell, expansion or interpolation. }
    Token := ''; Quote := #0; TokenStarted := False;
    for I := 1 to Length(Parameters) do begin
      if (Parameters[I] = '"') or (Parameters[I] = #39) then begin
        TokenStarted := True;
        if Quote = #0 then Quote := Parameters[I]
        else if Quote = Parameters[I] then Quote := #0
        else Token := Token + Parameters[I];
      end else if (Parameters[I] in [' ', #9]) and (Quote = #0) then begin
        if TokenStarted then begin Child.Parameters.Add(Token); Token := ''; TokenStarted := False; end;
      end else begin Token := Token + Parameters[I]; TokenStarted := True; end;
    end;
    if Quote <> #0 then raise Exception.Create('Unclosed quote in compiler flags');
    if TokenStarted then Child.Parameters.Add(Token);
    for I := Low(Arguments) to High(Arguments) do Child.Parameters.Add(Arguments[I]);
    Child.Options := [poUsePipes, poStderrToOutPut];
    Child.Execute;
    Result := '';
    repeat
      while Child.Output.NumBytesAvailable > 0 do begin
        N := Child.Output.Read(Buffer, SizeOf(Buffer));
        if N <= 0 then Break;
        SetString(Chunk, PChar(@Buffer[0]), N);
        Result := Result + Chunk;
      end;
      if Child.Running then Sleep(5);
    until not Child.Running and (Child.Output.NumBytesAvailable = 0);
    Child.WaitOnExit;
    if Child.ExitStatus <> 0 then
      raise Exception.CreateFmt('Compiler exited with status %d: %s', [Child.ExitCode, Result]);
  finally Child.Free; end;
end;

function RunNativeCommand(const Executable, Parameters, WorkingDirectory: string): string;
begin Result := RunNativeProcess(Executable, Parameters, WorkingDirectory, []); end;

function RunNativeCompiler(const Executable, Flags, WorkingDirectory, SourceFile, OutputFile: string): string;
begin
  Result := RunNativeProcess(Executable, Flags, WorkingDirectory,
    ['-c', NativePath(SourceFile), '-o', NativePath(OutputFile)]);
end;

end.
