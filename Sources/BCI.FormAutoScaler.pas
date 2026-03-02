// * --------------------------------------------------------------------------*
// * BCI.FormAutoScaler                                                        *
// *                                                                           *
// * Non-visual component for automatic proportional scaling of forms.        *
// * Once placed on a form in the IDE, it automatically handles               *
// * the resizing of all controls and fonts proportionally and idempotently.  *
// *                                                                           *
// * Usage:                                                                    *
// *   1. Drop the component onto the form (drag & drop from the BCI palette) *
// *   2. In FormShow, set Active := True                                      *
// *   3. (Optional) Hook OnAfterScale to scale controls created at runtime   *
// *                                                                           *
// * Note: fonts of all controls are acquired automatically.                  *
// * --------------------------------------------------------------------------*
unit BCI.FormAutoScaler;

interface

uses
  System.SysUtils, System.Classes, System.Math, System.TypInfo,
  Winapi.Windows, Winapi.Messages,
  Vcl.Controls, Vcl.Forms, Vcl.Graphics;

type
  TBCIFormAutoScaler = class(TComponent)
  private type
    // * ------------------------------------------------------------------*
    // * Record storing the original position and size of a control.       *
    // * Captured once in Loaded.                                          *
    // * ------------------------------------------------------------------*
    TControlOrigBounds = record
      Ctrl: TControl;
      Left, Top, Width, Height: Integer;
    end;

    // * ------------------------------------------------------------------*
    // * Record storing a reference to a TFont and its original Height.   *
    // * Used to scale fonts proportionally.                               *
    // * ------------------------------------------------------------------*
    TFontOrigInfo = record
      Font: TFont;
      OrigHeight: Integer;
    end;

  private
    // -- Original form dimensions (captured in Loaded) --
    FOrigClientWidth: Integer;
    FOrigClientHeight: Integer;

    // -- Snapshot of controls and fonts --
    FControlBounds: TArray<TControlOrigBounds>;
    FFonts: TArray<TFontOrigInfo>;

    // -- Internal state --
    FActive: Boolean;       // True = scaling enabled (responds to WM_SIZE)
    FStored: Boolean;       // True after Loaded has captured the snapshot
    FHooked: Boolean;       // True if the form's WindowProc is hooked

    // -- WindowProc hook --
    FOldWindowProc: TWndMethod;

    // -- Published event --
    FOnAfterScale: TNotifyEvent;

    // -- Internal methods --
    procedure CollectAllControls(aParent: TWinControl);
    procedure StoreSnapshot;
    procedure ApplyScale;
    procedure HookWindowProc;
    procedure UnhookWindowProc;
    procedure HookedWindowProc(var Msg: TMessage);
    procedure SetActive(const Value: Boolean);
    function GetOwnerForm: TCustomForm;

  protected
    // * ------------------------------------------------------------------*
    // * Loaded: called after the DFM has been fully loaded.               *
    // * Captures the original dimensions of all controls and hooks        *
    // * the owner form's WindowProc to intercept WM_SIZE.                 *
    // * No-op at design-time (csDesigning).                               *
    // * ------------------------------------------------------------------*
    procedure Loaded; override;

    // * ------------------------------------------------------------------*
    // * Notification: unhooks the WindowProc if the owner is removed.     *
    // * ------------------------------------------------------------------*
    procedure Notification(AComponent: TComponent;
      Operation: TOperation); override;

  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    // * ------------------------------------------------------------------*
    // * Registers an additional font for proportional scaling.            *
    // * Must be called BEFORE setting Active := True                      *
    // * (typically in FormCreate). The font's current height is captured  *
    // * as the original reference value.                                  *
    // *                                                                   *
    // * Parameters:                                                       *
    // *    aFont : the TFont to register (e.g. edPatientId.Font)         *
    // * ------------------------------------------------------------------*
    procedure AddFont(aFont: TFont);

    // -- Original form dimensions (read-only) --
    // Useful for external calculations (e.g. scaling of runtime controls)
    property OrigClientWidth: Integer read FOrigClientWidth;
    property OrigClientHeight: Integer read FOrigClientHeight;

  published
    // * ------------------------------------------------------------------*
    // * Active: enables scaling.                                          *
    // * When set to True, runs the first ApplyScale immediately and       *
    // * then responds automatically to WM_SIZE.                           *
    // * Replaces the old FInitialized + TFormScaler.Apply pattern.        *
    // * ------------------------------------------------------------------*
    property Active: Boolean read FActive write SetActive default False;

    // * ------------------------------------------------------------------*
    // * OnAfterScale: fires after each scaling pass.                      *
    // * Use this event to rescale controls created dynamically at runtime *
    // * (e.g. buttons generated from a DataSet).                          *
    // * ------------------------------------------------------------------*
    property OnAfterScale: TNotifyEvent read FOnAfterScale write FOnAfterScale;
  end;

implementation

// * --------------------------------------------------------------------------*
// * Constructor: initialises all fields to their default values.             *
// * --------------------------------------------------------------------------*
constructor TBCIFormAutoScaler.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FActive := False;
  FStored := False;
  FHooked := False;
  FOrigClientWidth := 0;
  FOrigClientHeight := 0;
  SetLength(FControlBounds, 0);
  SetLength(FFonts, 0);
end;

// * --------------------------------------------------------------------------*
// * Destructor: unhooks the WindowProc before destruction to avoid           *
// * access violations on the owner form.                                      *
// * --------------------------------------------------------------------------*
destructor TBCIFormAutoScaler.Destroy;
begin
  UnhookWindowProc;
  inherited Destroy;
end;

// * --------------------------------------------------------------------------*
// * Loaded: called by the VCL after the DFM has been fully loaded.           *
// * At this point all controls exist and have their design-time dimensions   *
// * (possibly already DPI-scaled by the VCL).                                *
// * Captures the snapshot and hooks WM_SIZE. No-op at design-time.           *
// * --------------------------------------------------------------------------*
procedure TBCIFormAutoScaler.Loaded;
begin
  inherited Loaded;
  if csDesigning in ComponentState then
    Exit;
  StoreSnapshot;
  HookWindowProc;
end;

// * --------------------------------------------------------------------------*
// * Notification: if the owner form is removed, unhooks the WindowProc       *
// * to prevent HookedWindowProc from being called on a destroyed form.       *
// * --------------------------------------------------------------------------*
procedure TBCIFormAutoScaler.Notification(AComponent: TComponent;
  Operation: TOperation);
begin
  inherited Notification(AComponent, Operation);
  if (Operation = opRemove) and (AComponent = Owner) then
    UnhookWindowProc;
end;

// * --------------------------------------------------------------------------*
// * GetOwnerForm: returns the Owner cast to TCustomForm,                     *
// * or nil if the Owner is not a form.                                        *
// * --------------------------------------------------------------------------*
function TBCIFormAutoScaler.GetOwnerForm: TCustomForm;
begin
  if (Owner <> nil) and (Owner is TCustomForm) then
    Result := TCustomForm(Owner)
  else
    Result := nil;
end;

// * --------------------------------------------------------------------------*
// * CollectAllControls: recursively traverses all child controls of aParent. *
// * Saves the current dimensions of each control in FControlBounds.          *
// * TWinControl descendants are traversed recursively to capture nested      *
// * controls (e.g. controls inside a ScrollBox or Panel).                    *
// * For each control that publishes a "Font" property, the font is added     *
// * automatically to FFonts (duplicates are skipped).                        *
// * --------------------------------------------------------------------------*
procedure TBCIFormAutoScaler.CollectAllControls(aParent: TWinControl);
var
  I, lIdx, J: Integer;
  C: TControl;
  lFont: TFont;
  lAlreadyAdded: Boolean;
begin
  for I := 0 to aParent.ControlCount - 1 do
  begin
    C := aParent.Controls[I];
    lIdx := Length(FControlBounds);
    SetLength(FControlBounds, lIdx + 1);
    FControlBounds[lIdx].Ctrl := C;
    FControlBounds[lIdx].Left := C.Left;
    FControlBounds[lIdx].Top := C.Top;
    FControlBounds[lIdx].Width := C.Width;
    FControlBounds[lIdx].Height := C.Height;

    // Automatically acquire the control's font if it is a published property
    if IsPublishedProp(C, 'Font') then
    begin
      lFont := TFont(GetObjectProp(C, 'Font', TFont));
      if lFont <> nil then
      begin
        lAlreadyAdded := False;
        for J := 0 to High(FFonts) do
          if FFonts[J].Font = lFont then
          begin
            lAlreadyAdded := True;
            Break;
          end;
        if not lAlreadyAdded then
        begin
          lIdx := Length(FFonts);
          SetLength(FFonts, lIdx + 1);
          FFonts[lIdx].Font := lFont;
          FFonts[lIdx].OrigHeight := lFont.Height;
        end;
      end;
    end;

    if C is TWinControl then
      CollectAllControls(TWinControl(C));
  end;
end;

// * --------------------------------------------------------------------------*
// * StoreSnapshot: captures the original form dimensions, initialises FFonts *
// * with the form's own font as element 0, then recursively collects the     *
// * bounds and fonts of all child controls via CollectAllControls.           *
// * Called exactly once from Loaded.                                          *
// * --------------------------------------------------------------------------*
procedure TBCIFormAutoScaler.StoreSnapshot;
var
  lForm: TCustomForm;
begin
  lForm := GetOwnerForm;
  if lForm = nil then
    Exit;

  FOrigClientWidth := lForm.ClientWidth;
  FOrigClientHeight := lForm.ClientHeight;

  // Initialise FFonts with the form's font (always present as element 0)
  SetLength(FFonts, 1);
  FFonts[0].Font := lForm.Font;
  FFonts[0].OrigHeight := lForm.Font.Height;

  // Recursively collect bounds and fonts of all child controls.
  // CollectAllControls appends to FFonts the fonts published by each control
  // (skipping duplicates) so that every distinct font is scaled proportionally.
  SetLength(FControlBounds, 0);
  CollectAllControls(lForm);

  FStored := True;
end;

// * --------------------------------------------------------------------------*
// * AddFont: registers an additional font for proportional scaling.          *
// * The font's current height is captured as the original reference value.   *
// * Call BEFORE setting Active := True (typically in FormCreate).            *
// *                                                                           *
// * Parameters:                                                               *
// *    aFont : the TFont to add to the scaling list                          *
// * --------------------------------------------------------------------------*
procedure TBCIFormAutoScaler.AddFont(aFont: TFont);
var
  lIdx: Integer;
begin
  if aFont = nil then
    Exit;
  lIdx := Length(FFonts);
  SetLength(FFonts, lIdx + 1);
  FFonts[lIdx].Font := aFont;
  FFonts[lIdx].OrigHeight := aFont.Height;
end;

// * --------------------------------------------------------------------------*
// * ApplyScale: applies proportional scaling to all controls and registered  *
// * fonts. IDEMPOTENT: always computes values from the ORIGINAL dimensions   *
// * saved in StoreSnapshot, never from current values. Can be called N times *
// * with identical results.                                                   *
// *                                                                           *
// * Formulae:                                                                 *
// *    ScaleX    = ClientWidth  / OrigClientWidth   (Left and Width)         *
// *    ScaleY    = ClientHeight / OrigClientHeight  (Top and Height)         *
// *    ScaleFont = Min(ScaleX, ScaleY)  (prevents text overflow)             *
// *                                                                           *
// * Fires OnAfterScale when done, if assigned.                               *
// * --------------------------------------------------------------------------*
procedure TBCIFormAutoScaler.ApplyScale;
var
  lForm: TCustomForm;
  I: Integer;
  lScaleX, lScaleY, lScaleFont: Double;
begin
  if not FStored then
    Exit;
  if (FOrigClientWidth = 0) or (FOrigClientHeight = 0) then
    Exit;

  lForm := GetOwnerForm;
  if lForm = nil then
    Exit;

  lScaleX := lForm.ClientWidth / FOrigClientWidth;
  lScaleY := lForm.ClientHeight / FOrigClientHeight;
  lScaleFont := Min(lScaleX, lScaleY);

  lForm.DisableAlign;
  try
    for I := 0 to High(FControlBounds) do
      FControlBounds[I].Ctrl.SetBounds(
        Round(FControlBounds[I].Left * lScaleX),
        Round(FControlBounds[I].Top * lScaleY),
        Round(FControlBounds[I].Width * lScaleX),
        Round(FControlBounds[I].Height * lScaleY));

    for I := 0 to High(FFonts) do
      FFonts[I].Font.Height := Round(FFonts[I].OrigHeight * lScaleFont);
  finally
    lForm.EnableAlign;
  end;

  if Assigned(FOnAfterScale) then
    FOnAfterScale(Self);
end;

// * --------------------------------------------------------------------------*
// * SetActive: setter for the Active property.                               *
// * When set to True (outside design-time), runs the first ApplyScale.       *
// * From that point on, HookedWindowProc responds to WM_SIZE.               *
// * --------------------------------------------------------------------------*
procedure TBCIFormAutoScaler.SetActive(const Value: Boolean);
begin
  if FActive = Value then
    Exit;
  FActive := Value;
  if csDesigning in ComponentState then
    Exit;
  if FActive and FStored then
    ApplyScale;
end;

// * --------------------------------------------------------------------------*
// * HookWindowProc: replaces the owner form's WindowProc with               *
// * HookedWindowProc, saving the original in FOldWindowProc.                *
// * This allows intercepting WM_SIZE without using the OnResize event        *
// * (which is single-cast and would overwrite any existing user handler).    *
// * --------------------------------------------------------------------------*
procedure TBCIFormAutoScaler.HookWindowProc;
var
  lForm: TCustomForm;
begin
  if FHooked then
    Exit;
  lForm := GetOwnerForm;
  if lForm = nil then
    Exit;
  FOldWindowProc := lForm.WindowProc;
  lForm.WindowProc := HookedWindowProc;
  FHooked := True;
end;

// * --------------------------------------------------------------------------*
// * UnhookWindowProc: restores the original WindowProc of the owner form.   *
// * Called by the destructor and by Notification(opRemove).                  *
// * --------------------------------------------------------------------------*
procedure TBCIFormAutoScaler.UnhookWindowProc;
var
  lForm: TCustomForm;
begin
  if not FHooked then
    Exit;
  lForm := GetOwnerForm;
  if (lForm <> nil) and Assigned(FOldWindowProc) then
    lForm.WindowProc := FOldWindowProc;
  FHooked := False;
  FOldWindowProc := nil;
end;

// * --------------------------------------------------------------------------*
// * HookedWindowProc: replacement WindowProc for the owner form.            *
// * Delegates to the original WindowProc (FOldWindowProc) first, then       *
// * applies proportional scaling if the message is WM_SIZE and the          *
// * component is both Active and Stored.                                     *
// * --------------------------------------------------------------------------*
procedure TBCIFormAutoScaler.HookedWindowProc(var Msg: TMessage);
begin
  if Assigned(FOldWindowProc) then
    FOldWindowProc(Msg);

  if (Msg.Msg = WM_SIZE) and FActive and FStored then
    ApplyScale;
end;

end.
