# BCI.FormAutoScaler

A non-visual Delphi VCL component that automatically scales all controls and fonts on a form proportionally whenever the form is resized.

---

## How it works

When the form finishes loading (`Loaded`), the component takes a **snapshot** of:

- the form's original `ClientWidth` and `ClientHeight`;
- the original bounds (`Left`, `Top`, `Width`, `Height`) of every control on the form, recursively, including controls nested inside panels, scroll boxes, etc.;
- the original `Font.Height` of the form and of every control that exposes a published `Font` property (acquired automatically via RTTI).

When `Active` is set to `True`, the component immediately applies scaling relative to the snapshot and then hooks the form's `WindowProc` to intercept every subsequent `WM_SIZE` message.

Every resize triggers `ApplyScale`, which recomputes positions and sizes from the **original** values — never from the current ones — making the operation fully **idempotent**.

### Scaling formulae

| Target | Factor |
|---|---|
| `Left`, `Width` | `ScaleX = ClientWidth / OrigClientWidth` |
| `Top`, `Height` | `ScaleY = ClientHeight / OrigClientHeight` |
| `Font.Height` | `ScaleFont = Min(ScaleX, ScaleY)` |

Font scaling uses the minimum of the two axes to prevent text from overflowing its container.

---

## Installation

1. Add `BCI.FormAutoScaler.pas` to the `BCI.Runtime` package.
2. Register the component (see `BCI.Register.Components.pas`) so it appears in the **BCI** palette category.
3. Rebuild and install the package in the IDE.

---

## Basic usage

### 1. Drop the component on the form

Drag `TBCIFormAutoScaler` from the BCI palette onto your form. The IDE assigns it a default name such as `BCIFormAutoScaler1`.

### 2. Enable scaling in `FormShow`

```pascal
procedure TForm1.FormShow(Sender: TObject);
begin
  BCIFormAutoScaler1.Active := True;
end;
```

That is all that is required for the typical case. All controls and their fonts are handled automatically.

---

## Advanced usage

### Registering extra fonts (runtime-only fonts)

Fonts that belong to controls already on the form at design-time are collected automatically. If you create objects at runtime that own their own `TFont` instance and you want those fonts to be scaled too, call `AddFont` **before** setting `Active := True`:

```pascal
procedure TForm1.FormCreate(Sender: TObject);
begin
  // MyChart owns its own TFont not associated with any VCL control
  BCIFormAutoScaler1.AddFont(MyChart.TitleFont);
end;

procedure TForm1.FormShow(Sender: TObject);
begin
  BCIFormAutoScaler1.Active := True;
end;
```

### Scaling controls created at runtime

Controls added dynamically after `Loaded` are not in the snapshot and will not be repositioned automatically. Use the `OnAfterScale` event to handle them:

```pascal
procedure TForm1.FormCreate(Sender: TObject);
begin
  BCIFormAutoScaler1.OnAfterScale := AfterScale;
end;

procedure TForm1.AfterScale(Sender: TObject);
var
  lScaleX, lScaleY: Double;
begin
  lScaleX := ClientWidth  / BCIFormAutoScaler1.OrigClientWidth;
  lScaleY := ClientHeight / BCIFormAutoScaler1.OrigClientHeight;

  DynamicButton.SetBounds(
    Round(FOrigButtonLeft  * lScaleX),
    Round(FOrigButtonTop   * lScaleY),
    Round(FOrigButtonWidth * lScaleX),
    Round(FOrigButtonHeight * lScaleY));
end;
```

`OrigClientWidth` and `OrigClientHeight` are read-only properties that expose the form's original dimensions for use in external calculations like this.

---

## Reference

### Properties

| Property | Type | Default | Description |
|---|---|---|---|
| `Active` | `Boolean` | `False` | Enables scaling. Setting to `True` triggers the first `ApplyScale` immediately and starts listening to `WM_SIZE`. |
| `OrigClientWidth` | `Integer` | — | Original `ClientWidth` of the form at load time (read-only). |
| `OrigClientHeight` | `Integer` | — | Original `ClientHeight` of the form at load time (read-only). |

### Events

| Event | Signature | Description |
|---|---|---|
| `OnAfterScale` | `TNotifyEvent` | Fires after every scaling pass. Use it to manually rescale runtime-created controls. |

### Methods

| Method | Description |
|---|---|
| `AddFont(aFont: TFont)` | Registers an additional font for proportional scaling. Call before `Active := True`. |

---

## Design notes

- **Idempotent scaling.** All scaling is computed from the original snapshot values. Calling `ApplyScale` multiple times at the same form size produces the same result.
- **WindowProc hook.** The component hooks `WindowProc` rather than `OnResize` to avoid replacing any handler the developer may have already assigned. The original `WindowProc` is always called first before scaling is applied.
- **Automatic font discovery.** RTTI (`IsPublishedProp` / `GetObjectProp`) is used to detect and register the `Font` property of every control automatically, with pointer-equality checks to avoid duplicate entries.
- **Design-time safe.** All runtime logic is guarded by `csDesigning in ComponentState` checks; the component is fully inert inside the IDE.
- **Cleanup on destroy.** The destructor and `Notification(opRemove)` both unhook `WindowProc` to prevent access violations if the component or form is destroyed in an unexpected order.
