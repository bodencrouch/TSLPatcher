unit UCLIOptions;

interface

uses SysUtils, Classes;

type
ECLIError = class(Exception)
  Code: integer;
  constructor CreateCode(ExitCode: integer; const Text: string);
end;
TCLIOptions = record
  Help, Version, Install, Uninstall, Validate, List, Summary, Info, Yes,
  Console, Terminal, LowercasePaths, HasIndex: boolean;
  Game, GameDir, ModPath, Namespace, IniName, InfoName: string;
  Index, LogLevel: integer;
end;
procedure ParseOptions(out Options: TCLIOptions);
procedure PrintHelp;

implementation
constructor ECLIError.CreateCode(ExitCode: integer; const Text: string);
begin
  inherited Create(Text);
  Code := ExitCode;
end;
function Nonnegative(const Text: string): integer;

var Digits, Maximum: string;
Index: integer;
begin
  Digits := Text;
  if (Digits <> '') and (Digits[1] = '+') then Delete(Digits,1,1);
  if Digits = '' then raise ECLIError.CreateCode(2, 'Expected a nonnegative integer');
  for Index := 1 to Length(Digits) do
  if not (Digits[Index] In ['0'..'9']) then raise ECLIError.CreateCode(2, 'Invalid nonnegative integer: ' + Text);
  while (Length(Digits) > 1) and (Digits[1] = '0') do
  Delete(Digits,1,1);
  if SizeOf(Pointer) = 8 then Maximum := '18446744073709551615'
  else Maximum := '4294967295';
  if (Length(Digits) > Length(Maximum)) or ((Length(Digits) = Length(Maximum)) and (Digits > Maximum)) then
  raise ECLIError.CreateCode(2, 'Integer out of range: ' + Text);
  // Any valid machine index above MaxInt is necessarily outside TStringList bounds.
  if not TryStrToInt(Digits, Result) then Result := MaxInt;
end;
procedure ParseOptions(out Options: TCLIOptions);

var ArgumentIndex, EqualsPosition: integer;
Arg, Value: string;
Positionals: TStringList;
HasValue: boolean;
function TakeValue: string;
begin
  if HasValue then Result := Value
  else
  begin
    Inc(ArgumentIndex);
    if ArgumentIndex > ParamCount then raise ECLIError.CreateCode(2, 'Missing value for ' + Arg);
    Result := ParamStr(ArgumentIndex);
  end;
end;
begin
  Options.Help := False;
  Options.Version := False;
  Options.Install := False;
  Options.Uninstall := False;
  Options.Validate := False;
  Options.List := False;
  Options.Summary := False;
  Options.Info := False;
  Options.Yes := False;
  Options.Console := False;
  Options.Terminal := False;
  Options.LowercasePaths := False;
  Options.HasIndex := False;
  Options.Game := '';
  Options.GameDir := '';
  Options.ModPath := '';
  Options.Namespace := '';
  Options.IniName := 'changes.ini';
  Options.InfoName := 'info.rtf';
  Options.Index := 0;
  Options.LogLevel := -1;
  Positionals := TStringList.Create;
  try
    ArgumentIndex := 1;
    while ArgumentIndex <= ParamCount do
    begin
      Arg := ParamStr(ArgumentIndex);
      HasValue := False;
      Value := '';
      if Copy(Arg, 1, 2) = '--' then
      begin
        EqualsPosition := Pos('=', Arg);
        if EqualsPosition > 0 then
        begin
          Value := Copy(Arg, EqualsPosition+1, MaxInt);
          Delete(Arg, EqualsPosition, MaxInt);
          HasValue := True;
        end;
      end;
      if (Arg = '-g') or (Arg = '--game') then Options.Game := TakeValue
      else if Arg = '--game-dir' then Options.GameDir := TakeValue
      else if Arg = '--tslpatchdata' then Options.ModPath := TakeValue
      else if (Arg = '-n') or (Arg = '--namespace') then Options.Namespace := TakeValue
      else if Arg = '--namespace-option-index' then
      begin
        Options.Index := Nonnegative(TakeValue);
        Options.HasIndex := True;
      end
      else if Arg = '--log-level' then
      begin
        Options.LogLevel := Nonnegative(TakeValue);
        if Options.LogLevel > 4 then raise ECLIError.CreateCode(2, 'Log level must be 0 through 4');
      end
      else
      begin
        if HasValue then raise ECLIError.CreateCode(2, 'Unexpected value for ' + Arg);
        if (Arg = '-h') or (Arg = '--help') then Options.Help := True
        else if (Arg = '-V') or (Arg = '--version') then Options.Version := True
        else if Arg = '--install' then Options.Install := True
        else if Arg = '--uninstall' then Options.Uninstall := True
        else if Arg = '--validate' then Options.Validate := True
        else if Arg = '--list' then Options.List := True
        else if Arg = '--summary' then Options.Summary := True
        else if Arg = '--info' then Options.Info := True
        else if (Arg = '-y') or (Arg = '--yes') then Options.Yes := True
        else if Arg = '--console' then Options.Console := True
        else if (Arg = '--cli') or (Arg = '--no-gui') then Options.Terminal := True
        else if Arg = '--experimental-lowercase-paths' then Options.LowercasePaths := True
        else if (Arg <> '') and (Arg[1] = '-') then raise ECLIError.CreateCode(2, 'Unknown option: ' + Arg)
        else if SameText(ExtractFileExt(Arg), '.ini') then Options.IniName := Arg
        else if SameText(ExtractFileExt(Arg), '.rtf') then Options.InfoName := Arg
        else Positionals.Add(Arg);
      end;
      Inc(ArgumentIndex);
    end;
    if not (Positionals.Count In [0,2,3]) then raise ECLIError.CreateCode(2, 'Expected GAME MOD [INDEX]');
    if Positionals.Count >= 2 then
    begin
      Options.GameDir := Positionals[0];
      Options.Game := Positionals[0];
      Options.ModPath := Positionals[1];
    end;
    if Positionals.Count = 3 then
    begin
      Options.Index := Nonnegative(Positionals[2]);
      Options.HasIndex := True;
    end;
  finally
    Positionals.Free;
  end;
end;
procedure PrintHelp;
begin
  WriteLn('TSLPatcher native console');
  WriteLn('Usage: TSLPatcher --tslpatchdata MOD [--game-dir GAME] --install|--uninstall|--validate');
  WriteLn('       TSLPatcher GAME MOD [INDEX] --install|--uninstall|--validate');
  WriteLn('       TSLPatcher --cli [-g GAME] [-n INDEX_OR_NAME] [-y]');
  WriteLn('Options: -h/--help, -V/--version, --namespace-option-index N, --log-level 0..4');
  WriteLn('         --list, --info, --summary, --console, --no-gui, --yes');
  WriteLn('         --experimental-lowercase-paths (compatibility no-op)');
  WriteLn('Long value options accept --option=value. Namespace indexes are zero-based.');
  WriteLn('Interactive operations discover tslpatchdata beside the executable.');
end;
end.
