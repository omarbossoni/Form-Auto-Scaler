unit BCI.Register.Components;

interface

procedure Register;

implementation

uses
  System.Classes,
  BCI.FormAutoScaler;

// * --------------------------------------------------------------------------*
// * Register - registra il componente nella palette BCI dell'IDE Delphi.      *
// * --------------------------------------------------------------------------*
procedure Register;
begin
  RegisterComponents('BCI', [TBCIFormAutoScaler]);
end;

end.
