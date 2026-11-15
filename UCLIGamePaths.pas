unit UCLIGamePaths;

interface

uses IniFiles;
function DetectGame(Config: TMemIniFile): string;

implementation

uses Classes, SysUtils, UCLIManifest, UPatcherPlatform
{$IFDEF MSWINDOWS}, Windows{$ENDIF};
function RegistryGame(GameNumber: integer): string;
{$IFDEF MSWINDOWS}

var Keys: array[0..1] of string;
Index: integer;
Key: HKEY;
Buffer: array[0..32767] of Char;
Size, Kind: DWORD;
{$ENDIF}
begin
  Result := '';
  {$IFDEF MSWINDOWS}
  if GameNumber = 1 then
  begin
    Keys[0] := 'SOFTWARE\BioWare\SW\KOTOR';
    Keys[1] := 'SOFTWARE\WOW6432Node\BioWare\SW\KOTOR';
  end
  else
  begin
    Keys[0] := 'SOFTWARE\LucasArts\KotOR2';
    Keys[1] := 'SOFTWARE\WOW6432Node\LucasArts\KotOR2';
  end;
  for Index := 0 to 1 do
  begin
    if RegOpenKeyEx(HKEY_LOCAL_MACHINE, PChar(Keys[Index]), 0, KEY_READ, Key) <> ERROR_SUCCESS then Continue
;
    try
      Size := SizeOf(Buffer);
      if (RegQueryValueEx(Key, 'Path', nil, @Kind, @Buffer[0], @Size) = ERROR_SUCCESS) and (Kind = REG_SZ)
      then
      begin
        Buffer[High(Buffer)] := #0;
        Result := PChar(@Buffer[0]);
        if SysUtils.DirectoryExists(Result) then Exit;
      end;
    finally
      RegCloseKey(Key);
    end;
  end;
  Result := '';
  {$ENDIF}
end;
function DetectGame(Config: TMemIniFile): string;

const Folders: array[0..7] of string = ('swkotor', 'Star Wars - KotOR', 'Knights of the Old Republic', 'STAR WARS - Knights of the Old Republic', 'Knights of the Old Republic II', 'Star Wars - KotOR2', 'swkotor2', 'STAR WARS - Knights of the Old Republic II - The Sith Lords');

var SteamRoots, Libraries, Found, Lines: TStringList;
UserDirectory, Path, Line: string;
RootIndex, FolderIndex, LineIndex, QuotePosition, RequestedGame: integer;
procedure AddGame(const Candidate: string);

var Resolved: string;
begin
  if Candidate = '' then Exit;
  try
    Resolved := CanonicalPath(Candidate);
    if SysUtils.FileExists(NativePath(Resolved + PathDelim + 'dialog.tlk')) and (Found.IndexOf(Resolved) < 0)
    then Found.Add(Resolved);
  except
    // An inaccessible auto-detection candidate does not override an explicit path or prompt.
  end;
end;
begin
  Result := '';
  // The CLI requested-game contract is independent of the legacy GUI switch.
  if TryStrToInt(Trim(Config.ReadString('Settings', 'LookupGameNumber', '')), RequestedGame)
    and (RequestedGame in [1, 2]) then
  begin
    Result := RegistryGame(RequestedGame);
    if Result <> '' then Exit;
  end;
  SteamRoots := TStringList.Create;
  Libraries := TStringList.Create;
  Found := TStringList.Create;
  Lines := TStringList.Create;
  try
    AddGame(RegistryGame(1));
    AddGame(RegistryGame(2));
    UserDirectory := GetEnvironmentVariable('HOME');
    if UserDirectory = '' then UserDirectory := GetEnvironmentVariable('USERPROFILE');
    {$IFDEF MSWINDOWS}
    SteamRoots.Add('C:\Program Files (x86)\Steam');
    SteamRoots.Add('C:\Program Files\Steam');
    Libraries.Add('C:\GOG Games');
    Libraries.Add('C:\Program Files (x86)\LucasArts');
    Libraries.Add('C:\Program Files\LucasArts');
    {$ELSE}
    if UserDirectory <> '' then
    begin
      SteamRoots.Add(UserDirectory + '/.steam/steam');
      SteamRoots.Add(UserDirectory + '/.steam/root');
      SteamRoots.Add(UserDirectory + '/.local/share/Steam');
      SteamRoots.Add(UserDirectory + '/.var/app/com.valvesoftware.Steam/.local/share/Steam');
      Libraries.Add(UserDirectory + '/Games');
      Libraries.Add(UserDirectory + '/GOG Games');
    end;
    {$ENDIF}
    for RootIndex := 0 to SteamRoots.Count-1 do
    begin
      Libraries.Add(SteamRoots[RootIndex] + '/steamapps/common');
      Path := SteamRoots[RootIndex] + '/steamapps/libraryfolders.vdf';
      if not SysUtils.FileExists(Path) then Continue;
      try
        Lines.LoadFromFile(Path);
      except
        Continue;
      end;
      for LineIndex := 0 to Lines.Count-1 do
      begin
        Line := Trim(Lines[LineIndex]);
        if Copy(Line,1,6) <> '"path"' then Continue;
        Delete(Line,1,6);
        QuotePosition := Pos('"',Line);
        if QuotePosition = 0 then Continue;
        Delete(Line,1,QuotePosition);
        QuotePosition := Pos('"',Line);
        if QuotePosition = 0 then Continue;
        Path := StringReplace(Copy(Line,1,QuotePosition-1), '\\', '\', [rfReplaceAll]);
        Libraries.Add(Path + '/steamapps/common');
      end;
    end;
    for RootIndex := 0 to Libraries.Count-1 do
    if SysUtils.DirectoryExists(Libraries[RootIndex]) then
    for FolderIndex := 0 to High(Folders) do
    AddGame(Libraries[RootIndex] + PathDelim + Folders[FolderIndex]);
    if UserDirectory <> '' then
    begin
      AddGame(UserDirectory + '/.wine/drive_c/Program Files (x86)/LucasArts/SWKotOR');
      AddGame(UserDirectory + '/.wine/drive_c/Program Files (x86)/LucasArts/SWKotOR2');
    end;
    if Found.Count = 1 then Result := Found[0];
  finally
    Lines.Free;
    Found.Free;
    Libraries.Free;
    SteamRoots.Free;
  end;
end;
end.
