unit UCLIConfig;

interface

uses Classes, SysUtils, IniFiles;

type
TModSession = class
  public
  ModRoot, DataRoot, DataPath, IniPath, InfoPath, Compiler: string;
  Names, Sections: TStringList;
  Namespaces: TMemIniFile;
  Config: TMemIniFile;
  constructor Create(const Base, DefaultIni, DefaultInfo: string);
  destructor Destroy; override;
  procedure Select(Index: integer);
  procedure Load;
  procedure Validate(const Game: string; CheckSources: boolean; Destinations: TStrings);
  private
  FDefaultIni, FDefaultInfo: string;
end;
function PlainRTF(const Path: string): string;

implementation

uses UCLIOptions, UCLIManifest, UPatcherPlatform, UERFHandler;
constructor TModSession.Create(const Base, DefaultIni, DefaultInfo: string);

var ResolvedPath, NamespaceFile, Section: string;
Keys: TStringList;
SectionIndex: integer;
begin
  inherited Create;
  Names := TStringList.Create;
  Sections := TStringList.Create;
  FDefaultIni := DefaultIni;
  FDefaultInfo := DefaultInfo;
  ResolvedPath := CanonicalPath(Base);
  if SysUtils.DirectoryExists(NativePath(ResolvedPath + PathDelim + 'tslpatchdata')) then DataRoot := CanonicalPath(ResolvedPath + PathDelim + 'tslpatchdata')
  else DataRoot := ResolvedPath;
  if not SysUtils.DirectoryExists(DataRoot) then raise ECLIError.CreateCode(3, 'Mod not found: ' + Base);
  if SameText(ExtractFileName(DataRoot), 'tslpatchdata') then ModRoot := ExtractFileDir(DataRoot)
  else ModRoot := DataRoot;
  NamespaceFile := SafePath(DataRoot, 'namespaces.ini');
  if SysUtils.FileExists(NamespaceFile) then
  begin
    Namespaces := TMemIniFile.Create(NamespaceFile);
    Keys := TStringList.Create;
    try
      Namespaces.ReadSection('Namespaces', Keys);
      for SectionIndex := 0 to Keys.Count-1 do
      begin
        Section := Namespaces.ReadString('Namespaces', Keys[SectionIndex], '');
        if (Section = '') or not Namespaces.SectionExists(Section) then raise ECLIError.CreateCode(3, 'Invalid namespace: ' + Section);
        Sections.Add(Section);
        Names.Add(Namespaces.ReadString(Section, 'Name', Section));
      end;
      if Names.Count = 0 then raise ECLIError.CreateCode(3, 'Empty namespaces.ini');
    finally
      Keys.Free;
    end;
  end
  else
  begin
    if not SysUtils.FileExists(SafePath(DataRoot, FDefaultIni)) then raise ECLIError.CreateCode(3, 'No namespaces.ini or ' + FDefaultIni + ' in ' + DataRoot);
    Names.Add(ExtractFileName(ModRoot));
    Sections.Add('');
  end;
end;
destructor TModSession.Destroy;
begin
  Config.Free;
  Namespaces.Free;
  Sections.Free;
  Names.Free;
  inherited;
end;
procedure TModSession.Select(Index: integer);

var Section, Subdir, IniName, InfoName: string;
begin
  if (Index < 0) or (Index >= Names.Count) then raise ECLIError.CreateCode(4, 'Namespace index out of range');
  IniName := FDefaultIni;
  InfoName := FDefaultInfo;
  Subdir := '';
  if Assigned(Namespaces) then
  begin
    Section := Sections[Index];
    Subdir := Namespaces.ReadString(Section, 'DataPath', '');
    IniName := Namespaces.ReadString(Section, 'IniName', 'changes.ini');
    InfoName := Namespaces.ReadString(Section, 'InfoName', 'info.rtf');
  end;
  try
    DataPath := DataRoot;
    if Subdir <> '' then DataPath := SafePath(DataRoot, Subdir, True);
    IniPath := SafePath(DataPath, IniName);
    try
      InfoPath := SafePath(DataPath, InfoName);
    except
      InfoPath := '';
    end;
    if not SysUtils.FileExists(IniPath) then raise Exception.Create('Instructions missing: ' + IniPath);
    // Engine sources are relative to the selected instruction file's parent.
    DataPath := ExtractFileDir(IniPath);
    Compiler := SafePath(DataPath, 'nwnnsscomp.exe');
    if not SysUtils.FileExists(Compiler) then Compiler := SafePath(DataRoot, 'nwnnsscomp.exe');
  except
    on E: Exception do raise ECLIError.CreateCode(5, E.Message);
  end;
end;
procedure TModSession.Load;

var Lines: TStringList;
SectionIndex: integer;
Text: string;
InSection, HasSettings: boolean;
begin
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(IniPath);
    InSection := False;
    HasSettings := False;
    for SectionIndex := 0 to Lines.Count-1 do
    begin
      Text := Trim(Lines[SectionIndex]);
      if (Text = '') or (Text[1] In [';', '#']) then Continue;
      if Text[1] = '[' then
      begin
        if (Length(Text) < 3) or (Text[Length(Text)] <> ']') then raise Exception.CreateFmt('Malformed INI section at line %d', [ SectionIndex+1 ]);
        InSection := True;
        if SameText(Text, '[Settings]') then HasSettings := True;
      end
      else if not InSection or (Pos('=', Text) < 2) then raise Exception.CreateFmt('Malformed INI assignment at line %d', [SectionIndex+1]);
    end;
    FreeAndNil(Config);
    Config := TMemIniFile.Create(IniPath);
    if not HasSettings then raise Exception.Create('Missing [Settings] section');
  finally
    Lines.Free;
  end;
end;
procedure TModSession.Validate(const Game: string; CheckSources: boolean; Destinations: TStrings);

const Lists: array[0..4] of string = ('2DAList', 'GFFList', 'HACKList', 'CompileList', 'SSFList');

var Keys, Values, Settings, RequiredFiles, ActiveModifiers: TStringList;
SectionIndex, EntryIndex, Digit: integer;
Section, FileName, Source, Destination, ResolvedPath, Value, Required, RequiredMessage: string;
function TargetPath(const Relative: string): string;
begin
  if Game <> '' then Result := ManagedPath(Game, Relative)
  else Result := SafePath(ModRoot, Relative);
end;
procedure AddDestination(const Relative: string);

var Full: string;
begin
  Full := TargetPath(Relative);
  if (Game <> '') and (Copy(Full, 1, Length(IncludeTrailingPathDelimiter(DataRoot))) =
    IncludeTrailingPathDelimiter(DataRoot)) then
    raise Exception.Create('Installation destination overlaps package sources: ' + Relative);
  if (Game <> '') and (Copy(Full, 1, Length(IncludeTrailingPathDelimiter(SafePath(ModRoot, 'backup')))) = IncludeTrailingPathDelimiter(SafePath(ModRoot, 'backup'))) then
  raise Exception.Create('Installation destination overlaps backup metadata: ' + Relative);
  if Assigned(Destinations) and (Destinations.IndexOf(Full) < 0) then Destinations.Add(Full);
end;
procedure InspectModifiers(const Owner, Grammar: string; Nested: boolean);
var ModifierKeys: TStringList;
Index: integer;
Key, Reference, FieldType: string;
IsReference: boolean;
begin
  // A file-modifier section may also define a finite primitive field.
  // Only field-definition recursion participates in the cycle stack.
  if Nested then
  begin
    if ActiveModifiers.IndexOf(Owner) >= 0 then
      raise Exception.Create('Cyclic modifier section [' + Owner + ']');
    ActiveModifiers.Add(Owner);
  end;
  ModifierKeys := TStringList.Create;
  try
    Config.ReadSection(Owner, ModifierKeys);
    FieldType := Config.ReadString(Owner, 'FieldType', '');
    for Index := 0 to ModifierKeys.Count-1 do
    begin
      Key := ModifierKeys[Index];
      IsReference := False;
      if Grammar = '2DAList' then
        IsReference := (Pos('AddRow', Key) > 0) or (Pos('ChangeRow', Key) > 0) or
          (Pos('CopyRow', Key) > 0) or (Pos('AddColumn', Key) > 0)
      else if Grammar = 'GFFList' then
        IsReference := (Copy(Key, 1, 8) = 'AddField') and
          (not Nested or ((Length(Key) > 8) and
          ((FieldType = 'Struct') or (FieldType = 'List'))));
      if not IsReference then Continue;
      Reference := Config.ReadString(Owner, Key, '');
      if not Config.SectionExists(Reference) then
        raise Exception.Create('Missing modifier section [' + Reference + ']');
      // Row/column modifier keys are table data. Only GFF field sections recurse.
      if Grammar = 'GFFList' then InspectModifiers(Reference, Grammar, True);
    end;
  finally
    ModifierKeys.Free;
    if Nested then ActiveModifiers.Delete(ActiveModifiers.Count-1);
  end;
end;
procedure InspectFile(const Name, Dest: string; NeedSection, SourceOnly: boolean);
var SourceName, SavedName, Text, TargetRelative, ArchivePath: string;
IsDirectory, ExistingInput, ReplaceInput: boolean;
Archive: TERFHandler;
begin
  if Name = '' then raise Exception.Create('Empty file in [' + Section + ']');
  if NeedSection and not Config.SectionExists(Name) then
    raise Exception.Create('Missing [' + Name + '] modifiers');
  if NeedSection then InspectModifiers(Name, Section, False);
  SourceName := Config.ReadString(Name, '!SourceFile', Name);
  SavedName := Config.ReadString(Name, '!SaveAs', Name);
  Text := SafePath(DataPath, SourceName);
  // Both logical and renamed filenames are paths, including archive entries.
  SafePath(DataPath, Name);
  SafePath(DataPath, SavedName);
  ReplaceInput := (Section = 'GFFList') and Config.ReadBool(Name, '!ReplaceFile', False);
  if Section = 'CompileList' then SavedName := ChangeFileExt(SavedName, '.ncs');
  IsDirectory := SameText(Dest, 'override') or (ExtractFileExt(Dest) = '') or
    (Dest = '.') or (Dest = '.\');
  // InstallList accepts existing directories before applying its extension heuristic.
  if (Game <> '') and not NeedSection and (Section <> 'CompileList') then
  begin
    ArchivePath := SafePath(Game, Dest, True);
    if SysUtils.DirectoryExists(ArchivePath) then IsDirectory := True
    else if SysUtils.FileExists(ArchivePath) then IsDirectory := False;
  end;
  if IsDirectory then
  begin
    TargetRelative := IncludeTrailingPathDelimiter(StringReplace(Dest, '\', PathDelim,
      [rfReplaceAll])) + SavedName;
    AddDestination(TargetRelative);
    if CheckSources and not SysUtils.FileExists(Text) then
    begin
      if SourceOnly or ReplaceInput or (Game = '') or
        not SysUtils.FileExists(TargetPath(TargetRelative)) then
        raise Exception.Create('Missing source: ' + Text);
    end;
  end
  else
  begin
    AddDestination(Dest);
    ExistingInput := False;
    ArchivePath := TargetPath(Dest);
    if (Game <> '') and SysUtils.FileExists(ArchivePath) then
    begin
      // Use the original reader without extracting or saving any resources.
      if CheckSources then
      begin
        Archive := TERFHandler.Create(ArchivePath);
        try
          if not Archive.Loaded then raise Exception.Create('Invalid archive: ' + Dest);
          ExistingInput := (Section = 'GFFList') and not ReplaceInput and
            Archive.GetResourceExists(SavedName);
        finally
          Archive.Free;
        end;
      end;
    end
    else
    begin
      if not (SameText(ExtractFileExt(Dest), '.mod') or
        SameText(ExtractFileExt(Dest), '.rim') or
        SameText(ExtractFileExt(Dest), '.erf') or
        SameText(ExtractFileExt(Dest), '.sav')) then
        raise Exception.Create('Unsupported archive destination: ' + Dest);
      if CheckSources and (Game <> '') then
        raise Exception.Create('Missing destination archive: ' + Dest);
    end;
    if CheckSources and not ExistingInput and not SysUtils.FileExists(Text) then
      raise Exception.Create('Missing source: ' + Text);
  end;
end;

begin
  if not Assigned(Config) then Load;
  if CheckSources and (Game <> '') and not SysUtils.FileExists(SafePath(Game, 'dialog.tlk')) then
  raise Exception.Create('Game directory is missing dialog.tlk');
  Keys := TStringList.Create;
  Values := TStringList.Create;
  Settings := TStringList.Create;
  RequiredFiles := TStringList.Create;
  ActiveModifiers := TStringList.Create;
  try
    Config.ReadSection('Settings', Settings);
    for SectionIndex := 0 to Settings.Count-1 do
    begin
      if SameText(Copy(Settings[SectionIndex],1,8), 'Required') then
      begin
        Value := Copy(Settings[SectionIndex], 9, MaxInt);
        if SameText(Copy(Value,1,3), 'Msg') then Delete(Value,1,3);
        for Digit := 1 to Length(Value) do
        if not (Value[Digit] In ['0'..'9']) then raise Exception.Create('Invalid Required key: ' + Settings[SectionIndex]);
      end;
      if SameText(Copy(Settings[SectionIndex],1,8), 'Required') and not SameText(Copy(Settings[SectionIndex],1,11), 'RequiredMsg') then
      begin
        Required := Config.ReadString('Settings', Settings[SectionIndex], '');
        if Required = '' then Continue;
        RequiredFiles.Clear;
        ExtractStrings([','], [], PChar(Required), RequiredFiles);
        for EntryIndex := 0 to RequiredFiles.Count-1 do
        begin
          if Game <> '' then
            ResolvedPath := SafePath(Game, 'override' + PathDelim + Trim(RequiredFiles[EntryIndex]))
          else
            ResolvedPath := SafePath(ModRoot, 'override' + PathDelim + Trim(RequiredFiles[EntryIndex]));
          if (Game <> '') and not SysUtils.FileExists(ResolvedPath) then
          begin
            RequiredMessage := Trim(Config.ReadString('Settings',
              'RequiredMsg' + Copy(Settings[SectionIndex], 9, MaxInt), ''));
            if RequiredMessage = '' then
              RequiredMessage := 'Required file missing: ' + Trim(RequiredFiles[EntryIndex]);
            raise Exception.Create(RequiredMessage);
          end;
        end;
      end;
    end;
    Config.ReadSection('TLKList', Keys);
    if Keys.Count > 0 then
    begin
      AddDestination('dialog.tlk');
      Source := Config.ReadString('TLKList', '!SourceFile', 'append.tlk');
      ResolvedPath := SafePath(DataPath, Source);
      if CheckSources and not SysUtils.FileExists(ResolvedPath) then raise Exception.Create('Missing TLK source: ' + ResolvedPath);
      Source := Config.ReadString('TLKList', '!SourceFileF', 'appendf.tlk');
      ResolvedPath := SafePath(DataPath, Source);
      if SysUtils.FileExists(ResolvedPath) then AddDestination('dialogf.tlk');
    end;
    for SectionIndex := 0 to High(Lists) do
    begin
      Section := Lists[SectionIndex];
      Config.ReadSection(Section, Keys);
      for EntryIndex := 0 to Keys.Count-1 do
      begin
        if (Keys[EntryIndex] = '') or (Keys[EntryIndex][1] = '!') then Continue;
        FileName := Config.ReadString(Section, Keys[EntryIndex], '');
        Destination := 'override';
        if Section = 'CompileList' then Destination := Config.ReadString(Section, '!DefaultDestination', Destination);
        Destination := Config.ReadString(FileName, '!Destination', Destination);
        InspectFile(FileName, Destination, Section <> 'CompileList', Section = 'CompileList');
      end;
      if (Section = 'CompileList') and (Keys.Count > 0) and CheckSources and not SysUtils.FileExists(Compiler) then raise Exception.Create('Missing native compiler: ' + Compiler);
    end;
    Config.ReadSection('InstallList', Keys);
    for SectionIndex := 0 to Keys.Count-1 do
    begin
      Section := Keys[SectionIndex];
      Destination := Config.ReadString('InstallList', Section, '');
      if Destination = '' then Destination := '.';
      if not Config.SectionExists(Section) then raise Exception.Create('Missing install section [' + Section + ']');
      Config.ReadSection(Section, Values);
      for EntryIndex := 0 to Values.Count-1 do
      begin
        if (Values[EntryIndex] <> '') and (Values[EntryIndex][1] <> '!') then InspectFile(Config.ReadString(Section, Values[ EntryIndex], ''), Destination, False, True);
      end;
    end;
  finally
    ActiveModifiers.Free;
    RequiredFiles.Free;
    Settings.Free;
    Values.Free;
    Keys.Free;
  end;
end;
function PlainRTF(const Path: string): string;

var Lines: TStringList;
Text, Word: string;
SectionIndex, Depth, SkipDepth, N: integer;
Character: Char;
begin
  if not SysUtils.FileExists(Path) then
  begin
    Result := 'No description was provided for this mod.';
    Exit;
  end;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(Path);
    Text := Lines.Text;
  finally
    Lines.Free;
  end;
  if Copy(Text,1,5) <> '{\rtf' then
  begin
    Result := Text;
    Exit;
  end;
  Result := '';
  SectionIndex := 1;
  Depth := 0;
  SkipDepth := -1;
  while SectionIndex <= Length(Text) do
  begin
    Character := Text[SectionIndex];
    Inc(SectionIndex);
    if Character = '{' then Inc(Depth)
    else if Character = '}' then
    begin
      if Depth = SkipDepth then SkipDepth := -1;
      Dec(Depth);
    end
    else if Character = '\' then
    begin
      if SectionIndex > Length(Text) then Break;
      Character := Text[SectionIndex];
      Inc(SectionIndex);
      if Character In ['\','{','}'] then
      begin
        if SkipDepth < 0 then Result := Result + Character;
      end
      else if Character = '*' then SkipDepth := Depth
      else if Character = #39 then
      begin
        if TryStrToInt('$'+Copy(Text,SectionIndex,2),N) and (SkipDepth < 0) then Result :=
        Result
        + Chr
        (N);
        Inc(SectionIndex,2);
      end
      else
      begin
        Word := Character;
        while (SectionIndex <= Length(Text)) and (Text[SectionIndex] In ['a'..'z','A'..'Z']) do
        begin
          Word := Word + Text[SectionIndex];
          Inc(SectionIndex);
        end;
        while (SectionIndex <= Length(Text)) and (Text[SectionIndex] In ['-','0'..'9']) do
        Inc(SectionIndex);
        if (SectionIndex <= Length(Text)) and (Text[SectionIndex] = ' ') then Inc(SectionIndex);
        if (Word = 'fonttbl') or (Word = 'colortbl') or (Word = 'stylesheet') or (Word = 'pict') or (Word = 'info') then SkipDepth := Depth;
        if SkipDepth < 0 then
        begin
          if (Word = 'par') or (Word = 'line') then Result := Result + #10;
          if Word = 'tab' then Result := Result + #9;
        end;
      end;
    end
    else if (SkipDepth < 0) and not (Character In [#13,#10]) then Result := Result + Character;
  end;
end;
end.
