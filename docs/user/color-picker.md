# Color picker

Vibranium comes with a simple color picker that magnifies the screen and
samples the pixel under the pointer.
Use ++control++ + ++alt++ + ++c++ or the bar module (if enabled) to access it.

## Picking

The pick is modal: it takes the screen for as long as it runs.

| Action | What it does |
|---|---|
| Move the pointer | The lens magnifies the pixels under it |
| Wheel | Zooms the lens in and out |
| Left click | Picks the color and copies it to the clipboard |
| Right click, ++escape++ | Cancels the pick |

An open menu is closed when the pick starts, so the frozen frame is the
desktop and not the menu that was in the way. The pick is drawn over every
other overlay on the screen, the privacy dots included.

## Bar module

The bar module represents the color history.
You can access it by hovering over the icon.
To clear color history, right click on it.

Right click opens the picker island: a saturation and value field, a hue
slider, an opacity slider, and the color code next to the preview
square.

## Typing a color code

The color code is an input field, so a color can be typed instead of
dialled. Click the field to put the caret in it - the code it shows is
selected, so the first keystroke replaces it:

| Code | What it does |
|---|---|
| `#ff8800` | hex, with or without the `#` |
| `rgb(255, 136, 0)` | red, green and blue channels |
| `rgba(255, 136, 0, 0.5)` | the same, with an alpha channel |
| `hsl(30, 100%, 50%)` | hue, saturation and lightness |
| `hsv(30, 100%, 100%)` | hue, saturation and value |

The picker detects the format of the code you typed and follows it: the
format chip moves to it, and **Copy** puts that format on the clipboard.
A code that is not a color stays in the field while you write it, and is
discarded when you confirm it with ++enter++ or click away - the field
then goes back to the color it holds.

The xmark in the field's right edge empties it.

## Settings

**Vibranium Menu** -> **Settings** -> **Color Picker**:

| Setting | What it does |
|---|---|
| **Live HEX preview** | Shows the hex value live while you hover (readable text on the picker) |
| **Show selected color** | The notification after picking |
| **History size** | How many recent colors the bar tooltip keeps |
