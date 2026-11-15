unit UCLISummary;

interface

uses Classes, UCLIConfig;

procedure BuildSummary(Session: TModSession; const Game: string; Lines: TStrings);

implementation

uses SysUtils, UPatcherPlatform;

function IsEntry(const Key: string): Boolean;
begin
  Result := (Key <> '') and (Key[1] <> '!');
end;

procedure BuildSummary(Session: TModSession; const Game: string; Lines: TStrings);
const
  Lists: array[0..4] of string =
    ('2DAList', 'GFFList', 'HACKList', 'CompileList', 'SSFList');
var
  Keys, Files, Modifiers: TStringList;
  ListIndex, EntryIndex, FileIndex, ModifierIndex: Integer;
  Count, Added, Changed, Columns: Integer;
  Section, Key, Name, Source, Saved, Destination, Policy, Detail: string;
  Archive, ReplaceExisting: Boolean;

  function EffectiveName(const FileName, Directive: string): string;
  begin
    Result := Session.Config.ReadString(FileName, Directive, '');
    if Result = '' then Result := FileName;
  end;

  function GamePath(const Relative: string): string;
  begin
    if Game = '' then Result := 'game/' + StringReplace(Relative, '\', '/', [rfReplaceAll])
    else Result := NativePath(IncludeTrailingPathDelimiter(Game) + Relative);
  end;

  function SourcePath(const Relative: string): string;
  begin
    Result := NativePath(IncludeTrailingPathDelimiter(Session.DataPath) + Relative);
  end;

  procedure FileLine;
  var Target: string;
  begin
    if Archive then Target := GamePath(Destination) + ' [' + Saved + ']'
    else Target := GamePath(IncludeTrailingPathDelimiter(
      StringReplace(Destination, '\', PathDelim, [rfReplaceAll])) + Saved);
    Lines.Add('  ' + SourcePath(Source) + ' -> ' + Target);
    Lines.Add('    ' + Policy + ', ' + Detail);
  end;

  function EntryCount(Entries: TStrings): Integer;
  var Index: Integer;
  begin
    Result := 0;
    for Index := 0 to Entries.Count - 1 do
      if IsEntry(Entries[Index]) then Inc(Result);
  end;

begin
  Keys := TStringList.Create;
  Files := TStringList.Create;
  Modifiers := TStringList.Create;
  try
    Lines.Add('TSLPatcher configuration summary');
    Lines.Add('Instructions ' + Session.IniPath);
    Lines.Add('Sources ' + Session.DataPath);
    Lines.Add('Declared operations are subject to source data and runtime conditions.');
    Lines.Add('');
    Session.Config.ReadSection('TLKList', Keys);
    Count := EntryCount(Keys);
    Lines.Add('TLKList - ' + IntToStr(Count) + ' StrRef mappings');
    if Count > 0 then
    begin
      Source := Session.Config.ReadString('TLKList', '!SourceFile', 'append.tlk');
      Lines.Add('  ' + SourcePath(Source) + ' -> ' + GamePath('dialog.tlk'));
      Lines.Add('    append or reuse source entries');
      Source := Session.Config.ReadString('TLKList', '!SourceFileF', 'appendf.tlk');
      Lines.Add('  ' + SourcePath(Source) + ' -> ' + GamePath('dialogf.tlk'));
      Lines.Add('    append or reuse source entries when the female source exists');
    end;

    Lines.Add('');
    Lines.Add('InstallList');
    Count := 0;
    Session.Config.ReadSection('InstallList', Keys);
    for EntryIndex := 0 to Keys.Count - 1 do
    begin
      Section := Keys[EntryIndex];
      Destination := Session.Config.ReadString('InstallList', Section, '');
      if Destination = '' then Destination := '.';
      Archive := ExtractFileExt(Destination) <> '';
      if Game <> '' then
      begin
        if SysUtils.DirectoryExists(GamePath(Destination)) then Archive := False
        else if SysUtils.FileExists(GamePath(Destination)) then Archive := True;
      end;
      Session.Config.ReadSection(Section, Files);
      for FileIndex := 0 to Files.Count - 1 do
      begin
        Key := Files[FileIndex];
        if not IsEntry(Key) then Continue;
        Name := Session.Config.ReadString(Section, Key, '');
        Source := EffectiveName(Name, '!SourceFile');
        Saved := EffectiveName(Name, '!SaveAs');
        Policy := 'skip existing';
        if SameText(Copy(Key, 1, 7), 'replace') then
          Policy := 'overwrite existing';
        Detail := '1 file installation';
        FileLine;
        Inc(Count);
      end;
    end;
    Lines.Add('  ' + IntToStr(Count) + ' file installations');

    for ListIndex := 0 to High(Lists) do
    begin
      Section := Lists[ListIndex];
      Session.Config.ReadSection(Section, Keys);
      Lines.Add('');
      Lines.Add(Section + ' - ' + IntToStr(EntryCount(Keys)) + ' files');
      for EntryIndex := 0 to Keys.Count - 1 do
      begin
        Key := Keys[EntryIndex];
        if not IsEntry(Key) then Continue;
        Name := Session.Config.ReadString(Section, Key, '');
        Source := EffectiveName(Name, '!SourceFile');
        Saved := EffectiveName(Name, '!SaveAs');
        Destination := 'override';
        // Only GFF and CompileList consume a custom destination in the engine.
        if Section = 'CompileList' then
          Destination := Session.Config.ReadString(Section, '!DefaultDestination', Destination);
        if (Section = 'GFFList') or (Section = 'CompileList') then
          Destination := Session.Config.ReadString(Name, '!Destination', Destination);
        Archive := not SameText(Destination, 'override');
        Session.Config.ReadSection(Name, Modifiers);
        Count := EntryCount(Modifiers);
        Policy := 'modify existing or install source';
        Detail := IntToStr(Count) + ' requested instructions';
        if Section = '2DAList' then
        begin
          Added := 0;
          Changed := 0;
          Columns := 0;
          for ModifierIndex := 0 to Modifiers.Count - 1 do
          begin
            Key := Modifiers[ModifierIndex];
            if Pos('AddRow', Key) > 0 then Inc(Added)
            else if Pos('ChangeRow', Key) > 0 then Inc(Changed)
            else if Pos('AddColumn', Key) > 0 then Inc(Columns)
            else if Pos('CopyRow', Key) > 0 then Inc(Added);
          end;
          Detail := Format('%d new or copied rows, %d changed rows, %d new columns',
            [Added, Changed, Columns]);
        end
        else if Section = 'GFFList' then
        begin
          if Session.Config.ReadBool(Name, '!ReplaceFile', False) then
            Policy := 'overwrite existing from source, then modify';
          Detail := IntToStr(Count) + ' requested field instructions';
        end
        else if Section = 'HACKList' then
        begin
          ReplaceExisting := False;
          if (Modifiers.Count > 1) and SameText(Modifiers[0], 'ReplaceFile') then
            ReplaceExisting := Session.Config.ReadBool(Name, Modifiers[0], False);
          if Modifiers.IndexOf('ReplaceFile') >= 0 then Dec(Count);
          Policy := 'skip existing';
          if ReplaceExisting then Policy := 'overwrite existing from source';
          Detail := IntToStr(Count) + ' requested integer writes';
        end
        else if Section = 'CompileList' then
        begin
          // Native compilation writes a package path, then installs its basename.
          Saved := ExtractFileName(ChangeFileExt(
            StringReplace(Saved, '\', PathDelim, [rfReplaceAll]), '.ncs'));
          Policy := 'overwrite existing';
          if Archive and not SameText(Copy(Keys[EntryIndex], 1, 7), 'replace') then
            Policy := 'skip existing archive resource';
          Detail := '1 token-processing pass, compile when source has an entry point';
        end
        else if Section = 'SSFList' then
        begin
          if SameText(Copy(Keys[EntryIndex], 1, 7), 'replace') then
            Policy := 'overwrite existing from source, then modify';
          Detail := IntToStr(Count) + ' requested sound entries';
        end;
        FileLine;
      end;
    end;
  finally
    Modifiers.Free;
    Files.Free;
    Keys.Free;
  end;
end;

end.
