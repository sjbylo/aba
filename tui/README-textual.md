# ABA TUI - Textual Version

A modern, beautiful Text User Interface for ABA using Python Textual.

## Features

✨ **Modern UI**
- Beautiful, polished interface
- Mouse support
- Smooth scrolling
- CSS-like styling
- Keyboard shortcuts

🎯 **Complete Wizard Flow**
1. Welcome screen
2. Channel selection (stable/fast/candidate)
3. Version selection
4. Platform & Network configuration
5. Operator management (search, sets, basket)
6. Summary & Apply

🔍 **Advanced Operator Management**
- Multi-term search (AND logic)
- Operator sets (predefined groups)
- Visual basket management
- Check/uncheck to add/remove

🔗 **ABA Integration**
- Uses `replace-value-conf` for config management
- Calls `make catalog` for operator indexes
- Writes to `aba.conf` like the rest of ABA
- Background task support (with `run_once`)

## Installation

### Prerequisites
- Python 3.8+
- pip

### Install Dependencies

```bash
cd tui
pip install -r requirements-textual.txt
```

Or with a virtual environment:

```bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements-textual.txt
```

## Usage

```bash
./aba_tui_textual.py
```

Or if not executable:

```bash
python3 aba_tui_textual.py
```

### Keyboard Shortcuts

**Global:**
- `Q` - Quit
- `Esc` - Go back / Cancel

**Operators Screen:**
- `S` - Search operators
- `V` - View basket

**Navigation:**
- `Enter` - Select / Continue
- `Tab` - Move between elements
- `Arrow Keys` - Navigate lists
- `Space` - Check/uncheck

**Mouse:**
- Click buttons and options
- Scroll with mouse wheel

## Comparison: Textual vs Dialog

| Feature | Bash + Dialog | Python + Textual |
|---------|--------------|------------------|
| **UI Quality** | Good, traditional | Modern, beautiful |
| **Mouse Support** | No | Yes |
| **Scrolling** | Basic | Smooth |
| **Code Maintainability** | Hard (bash arrays, globals) | Easy (classes, methods) |
| **Error Handling** | Tricky (`set -e`) | Clean (try/except) |
| **Testing** | Difficult | Easy (unit tests) |
| **Dependencies** | dialog binary | pip install textual |
| **Learning Curve** | bash knowledge | Python knowledge |
| **File Size** | 1200+ lines | ~600 lines |

## Architecture

```
ABATUI (App)
├── WelcomeScreen
├── ChannelScreen
├── VersionScreen
├── PlatformScreen
├── OperatorsScreen
│   ├── OperatorSetsScreen
│   ├── OperatorSearchScreen
│   └── ViewBasketScreen
└── SummaryScreen
```

### Key Components

- **Screens**: Each step is a screen (like dialog screens)
- **Widgets**: Buttons, inputs, lists, checkboxes
- **Config Dict**: Stores all settings
- **Operators Set**: Manages selected operators
- **Background Tasks**: Placeholder for `run_once` integration

## Development

### Adding a New Screen

```python
class MyScreen(Screen):
    BINDINGS = [
        Binding("escape", "back", "Back"),
    ]
    
    def compose(self) -> ComposeResult:
        yield Header()
        yield Container(
            Static("[bold]My Title[/bold]"),
            # ... your widgets ...
            Button("Next", id="next"),
        )
        yield Footer()
    
    def on_button_pressed(self, event):
        if event.button.id == "next":
            self.app.push_screen(NextScreen())
```

### Styling

CSS is defined in the `ABATUI.CSS` string. Modify colors, spacing, borders, etc.

## TODO / Enhancements

- [ ] Integrate real `run_once` background tasks
- [ ] Add progress indicators for catalog download
- [ ] Network validation (CIDR, IP addresses)
- [ ] Resume from existing `aba.conf`
- [ ] Help screens with detailed info
- [ ] Operator set descriptions
- [ ] Multiple operator basket views (by set, alphabetical)
- [ ] Export/import configuration

## Advantages

1. **Better UX** - Modern, intuitive, mouse support
2. **Cleaner Code** - Object-oriented, easier to maintain
3. **Easier Testing** - Unit tests, mocking
4. **Better Error Handling** - Python exceptions vs bash traps
5. **Rich Features** - Progress bars, spinners, fancy layouts
6. **Active Development** - Textual is actively maintained

## Disadvantages

1. **Python Dependency** - Requires Python 3.8+
2. **Package Install** - Need `pip install textual`
3. **Different from ABA** - Rest of ABA is bash
4. **Learning Curve** - Team needs Python knowledge

## Recommendation

**For Production:** Start with dialog version (what we built). It works, is solid, and fits ABA's bash ecosystem.

**For Future:** Consider migrating to Textual when:
- Team comfortable with Python
- Want better maintainability
- Need advanced UI features
- Have time for migration

## Demo

To see what Textual can do:

```bash
# Run Textual's demo
python -m textual
```

This shows all available widgets and layouts!

