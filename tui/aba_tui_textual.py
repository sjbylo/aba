#!/usr/bin/env python3
"""
ABA TUI - Modern Text User Interface using Textual
A wizard-style interface for configuring OpenShift installations
"""

import os
import sys
import subprocess
import asyncio
from pathlib import Path

from textual.app import App, ComposeResult
from textual.containers import Container, Vertical, Horizontal, VerticalScroll
from textual.widgets import (
    Header, Footer, Button, Static, Label, Input, 
    Select, ListView, ListItem, Checkbox, OptionList
)
from textual.widgets.option_list import Option
from textual.screen import Screen
from textual import events
from textual.binding import Binding


# Get ABA_ROOT
ABA_ROOT = os.environ.get('ABA_ROOT', os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ABA_ROOT, 'scripts'))


class WelcomeScreen(Screen):
    """Welcome screen with ABA information"""
    
    BINDINGS = [
        Binding("enter", "continue", "Continue", show=True),
        Binding("escape,q", "quit", "Quit", show=True),
    ]
    
    def compose(self) -> ComposeResult:
        yield Header()
        yield Container(
            Static(
                "[bold cyan]ABA – OpenShift Installer[/bold cyan]\n\n"
                "Install & manage air-gapped OpenShift quickly with ABA.\n\n"
                "This wizard will guide you through:\n"
                "  • OpenShift channel and version selection\n"
                "  • Operator selection\n"
                "  • Platform and network configuration\n\n"
                "Configuration will be saved to aba.conf\n\n"
                "[dim]Press Enter to continue or Q to quit[/dim]",
                id="welcome-text"
            ),
            id="welcome-container"
        )
        yield Footer()
    
    def action_continue(self) -> None:
        """Move to channel selection"""
        self.app.push_screen(ChannelScreen())
    
    def action_quit(self) -> None:
        """Quit the application"""
        self.app.exit()


class ChannelScreen(Screen):
    """Select OCP update channel"""
    
    BINDINGS = [
        Binding("escape", "back", "Back", show=True),
    ]
    
    def compose(self) -> ComposeResult:
        yield Header()
        yield Container(
            Static("[bold]Select OpenShift Update Channel[/bold]\n", id="title"),
            Static(
                "Choose the update channel for your OpenShift installation:\n"
                "  • [cyan]stable[/cyan] - Recommended for production\n"
                "  • [yellow]fast[/yellow] - Latest GA releases\n"
                "  • [red]candidate[/red] - Preview/beta releases\n",
                id="channel-help"
            ),
            OptionList(
                Option("stable", id="stable"),
                Option("fast", id="fast"),
                Option("candidate", id="candidate"),
                id="channel-list"
            ),
            Horizontal(
                Button("Back", variant="default", id="back"),
                Button("Next", variant="primary", id="next"),
                id="button-row"
            ),
            id="channel-container"
        )
        yield Footer()
    
    def on_mount(self) -> None:
        """Set default selection"""
        option_list = self.query_one("#channel-list", OptionList)
        # Get current channel from config or default to stable
        current = self.app.config.get('ocp_channel', 'stable')
        if current == 'stable':
            option_list.highlighted = 0
        elif current == 'fast':
            option_list.highlighted = 1
        elif current == 'candidate':
            option_list.highlighted = 2
    
    def on_button_pressed(self, event: Button.Pressed) -> None:
        """Handle button clicks"""
        if event.button.id == "back":
            self.app.pop_screen()
        elif event.button.id == "next":
            option_list = self.query_one("#channel-list", OptionList)
            if option_list.highlighted is not None:
                selected = option_list.get_option_at_index(option_list.highlighted)
                self.app.config['ocp_channel'] = selected.id
                # Start background version fetch
                self.app.start_background_task(f"fetch_versions_{selected.id}")
                self.app.push_screen(VersionScreen())
    
    def on_option_list_option_selected(self, event: OptionList.OptionSelected) -> None:
        """Handle Enter key on option"""
        self.app.config['ocp_channel'] = event.option.id
        self.app.start_background_task(f"fetch_versions_{event.option.id}")
        self.app.push_screen(VersionScreen())
    
    def action_back(self) -> None:
        """Go back to welcome"""
        self.app.pop_screen()


class VersionScreen(Screen):
    """Select OCP version"""
    
    BINDINGS = [
        Binding("escape", "back", "Back", show=True),
    ]
    
    def compose(self) -> ComposeResult:
        yield Header()
        yield Container(
            Static("[bold]Select OpenShift Version[/bold]\n", id="title"),
            Static(
                f"Channel: [cyan]{self.app.config.get('ocp_channel', 'stable')}[/cyan]\n"
                "Select the version to install:\n",
                id="version-help"
            ),
            OptionList(
                Option("Loading versions...", id="loading", disabled=True),
                id="version-list"
            ),
            Horizontal(
                Button("Back", variant="default", id="back"),
                Button("Next", variant="primary", id="next"),
                id="button-row"
            ),
            id="version-container"
        )
        yield Footer()
    
    async def on_mount(self) -> None:
        """Fetch available versions"""
        await self.fetch_versions()
    
    async def fetch_versions(self) -> None:
        """Get latest and previous versions from ABA"""
        option_list = self.query_one("#version-list", OptionList)
        channel = self.app.config.get('ocp_channel', 'stable')
        
        # Simulate version fetch (in real app, call ABA scripts)
        # For now, use hardcoded values
        versions = {
            'stable': ['4.20.8', '4.19.21'],
            'fast': ['4.20.8', '4.19.21'],
            'candidate': ['4.21.0-rc.1', '4.20.8']
        }
        
        option_list.clear_options()
        for ver in versions.get(channel, ['4.20.8', '4.19.21']):
            option_list.add_option(Option(ver, id=ver))
        
        # Select current version if set
        current = self.app.config.get('ocp_version')
        if current:
            for i, opt in enumerate(option_list._options):
                if opt.id == current:
                    option_list.highlighted = i
                    break
    
    def on_button_pressed(self, event: Button.Pressed) -> None:
        """Handle button clicks"""
        if event.button.id == "back":
            self.app.pop_screen()
        elif event.button.id == "next":
            option_list = self.query_one("#version-list", OptionList)
            if option_list.highlighted is not None:
                selected = option_list.get_option_at_index(option_list.highlighted)
                self.app.config['ocp_version'] = selected.id
                # Write minimal config and start catalog download
                self.app.write_minimal_config()
                self.app.start_background_task("download_catalog")
                self.app.push_screen(PlatformScreen())
    
    def on_option_list_option_selected(self, event: OptionList.OptionSelected) -> None:
        """Handle Enter key on option"""
        self.app.config['ocp_version'] = event.option.id
        self.app.write_minimal_config()
        self.app.start_background_task("download_catalog")
        self.app.push_screen(PlatformScreen())
    
    def action_back(self) -> None:
        """Go back to channel"""
        self.app.pop_screen()


class PlatformScreen(Screen):
    """Configure platform and network settings"""
    
    BINDINGS = [
        Binding("escape", "back", "Back", show=True),
    ]
    
    def compose(self) -> ComposeResult:
        yield Header()
        yield VerticalScroll(
            Static("[bold]Platform & Network Configuration[/bold]\n", id="title"),
            Static("Configure your platform and network settings:\n"),
            Label("Platform:"),
            Select(
                [("Bare Metal", "bm"), ("VMware", "vmw")],
                value=self.app.config.get('platform', 'bm'),
                id="platform"
            ),
            Label("\nBase Domain:"),
            Input(
                placeholder="example.com",
                value=self.app.config.get('domain', 'example.com'),
                id="domain"
            ),
            Label("\nMachine Network (CIDR):"),
            Input(
                placeholder="10.0.0.0/24 (leave empty for auto-detect)",
                value=self.app.config.get('machine_network', ''),
                id="machine_network"
            ),
            Label("\nDNS Servers (comma-separated):"),
            Input(
                placeholder="8.8.8.8,1.1.1.1 (leave empty for auto-detect)",
                value=self.app.config.get('dns_servers', ''),
                id="dns_servers"
            ),
            Label("\nNTP Servers (comma-separated):"),
            Input(
                placeholder="pool.ntp.org (leave empty for auto-detect)",
                value=self.app.config.get('ntp_servers', ''),
                id="ntp_servers"
            ),
            Horizontal(
                Button("Back", variant="default", id="back"),
                Button("Next", variant="primary", id="next"),
                id="button-row"
            ),
            id="platform-container"
        )
        yield Footer()
    
    def on_button_pressed(self, event: Button.Pressed) -> None:
        """Handle button clicks"""
        if event.button.id == "back":
            self.app.pop_screen()
        elif event.button.id == "next":
            # Save all input values
            self.app.config['platform'] = self.query_one("#platform", Select).value
            self.app.config['domain'] = self.query_one("#domain", Input).value
            self.app.config['machine_network'] = self.query_one("#machine_network", Input).value
            self.app.config['dns_servers'] = self.query_one("#dns_servers", Input).value
            self.app.config['ntp_servers'] = self.query_one("#ntp_servers", Input).value
            self.app.push_screen(OperatorsScreen())
    
    def action_back(self) -> None:
        """Go back to version"""
        self.app.pop_screen()


class OperatorsScreen(Screen):
    """Manage operator selection"""
    
    BINDINGS = [
        Binding("escape", "back", "Back", show=True),
        Binding("s", "search", "Search", show=True),
        Binding("v", "view_basket", "View Basket", show=True),
    ]
    
    def compose(self) -> ComposeResult:
        yield Header()
        yield Container(
            Static("[bold]Operator Selection[/bold]\n", id="title"),
            Static(f"Operators in basket: [cyan]{len(self.app.operators)}[/cyan]\n"),
            Horizontal(
                Button("Select Set", variant="default", id="select_set"),
                Button("Search (S)", variant="default", id="search"),
                Button("View Basket (V)", variant="default", id="view_basket"),
                Button("Clear", variant="default", id="clear"),
                id="op-buttons"
            ),
            Horizontal(
                Button("Back", variant="default", id="back"),
                Button("Next →", variant="primary", id="next"),
                id="nav-buttons"
            ),
            id="operators-container"
        )
        yield Footer()
    
    def on_button_pressed(self, event: Button.Pressed) -> None:
        """Handle button clicks"""
        if event.button.id == "back":
            self.app.pop_screen()
        elif event.button.id == "next":
            self.app.push_screen(SummaryScreen())
        elif event.button.id == "search":
            self.action_search()
        elif event.button.id == "view_basket":
            self.action_view_basket()
        elif event.button.id == "select_set":
            self.app.push_screen(OperatorSetsScreen())
        elif event.button.id == "clear":
            self.app.operators.clear()
            self.update_basket_count()
    
    def update_basket_count(self) -> None:
        """Update the operator count display"""
        static = self.query_one(Static)
        if static.id != "title":  # Find the count static
            static.update(f"Operators in basket: [cyan]{len(self.app.operators)}[/cyan]\n")
    
    def action_search(self) -> None:
        """Open search dialog"""
        self.app.push_screen(OperatorSearchScreen())
    
    def action_view_basket(self) -> None:
        """View current operators"""
        self.app.push_screen(ViewBasketScreen())
    
    def action_back(self) -> None:
        """Go back to platform"""
        self.app.pop_screen()


class OperatorSetsScreen(Screen):
    """Select predefined operator sets"""
    
    BINDINGS = [
        Binding("escape", "back", "Back", show=True),
    ]
    
    def compose(self) -> ComposeResult:
        yield Header()
        yield Container(
            Static("[bold]Select Operator Sets[/bold]\n", id="title"),
            Static("Choose predefined operator sets to add:\n"),
            VerticalScroll(
                # Will be populated with checkboxes
                id="sets-list"
            ),
            Horizontal(
                Button("Cancel", variant="default", id="cancel"),
                Button("Add Selected", variant="primary", id="add"),
                id="button-row"
            ),
            id="sets-container"
        )
        yield Footer()
    
    async def on_mount(self) -> None:
        """Load available operator sets"""
        sets_list = self.query_one("#sets-list", VerticalScroll)
        
        # Get operator sets from templates directory
        templates_dir = Path(ABA_ROOT) / "templates"
        operator_sets = {}
        
        for file in templates_dir.glob("operator-set-*"):
            key = file.name.replace("operator-set-", "")
            # Read first line for description
            try:
                with open(file) as f:
                    desc = f.readline().strip().lstrip('#').strip()
            except:
                desc = key
            operator_sets[key] = desc
        
        # Add checkboxes for each set
        for key, desc in sorted(operator_sets.items()):
            checkbox = Checkbox(f"{key} - {desc}", id=f"set_{key}")
            await sets_list.mount(checkbox)
    
    def on_button_pressed(self, event: Button.Pressed) -> None:
        """Handle button clicks"""
        if event.button.id == "cancel":
            self.app.pop_screen()
        elif event.button.id == "add":
            # Get selected sets and add their operators
            sets_list = self.query_one("#sets-list", VerticalScroll)
            for checkbox in sets_list.query(Checkbox):
                if checkbox.value:  # If checked
                    set_key = checkbox.id.replace("set_", "")
                    self.add_operator_set(set_key)
            self.app.pop_screen()
    
    def add_operator_set(self, set_key: str) -> None:
        """Add operators from a set file"""
        set_file = Path(ABA_ROOT) / "templates" / f"operator-set-{set_key}"
        try:
            with open(set_file) as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith('#'):
                        # Remove inline comments
                        op = line.split('#')[0].strip()
                        if op:
                            self.app.operators.add(op)
        except Exception as e:
            pass  # Silently ignore errors
    
    def action_back(self) -> None:
        """Go back"""
        self.app.pop_screen()


class OperatorSearchScreen(Screen):
    """Search for operators"""
    
    BINDINGS = [
        Binding("escape", "cancel", "Cancel", show=True),
    ]
    
    def compose(self) -> ComposeResult:
        yield Header()
        yield Container(
            Static("[bold]Search Operators[/bold]\n", id="title"),
            Static("Enter search terms (space-separated, all must match):\n"),
            Input(placeholder="e.g. 'ki li' matches 'kiali'", id="search-input"),
            VerticalScroll(
                id="search-results"
            ),
            Horizontal(
                Button("Cancel", variant="default", id="cancel"),
                Button("Add Selected", variant="primary", id="add"),
                id="button-row"
            ),
            id="search-container"
        )
        yield Footer()
    
    def on_mount(self) -> None:
        """Focus search input"""
        self.query_one("#search-input", Input).focus()
    
    def on_input_submitted(self, event: Input.Submitted) -> None:
        """Search when Enter is pressed"""
        self.perform_search(event.value)
    
    def perform_search(self, query: str) -> None:
        """Search operator catalogs"""
        if len(query) < 2:
            return
        
        terms = query.lower().split()
        results_container = self.query_one("#search-results", VerticalScroll)
        results_container.remove_children()
        
        # Search in catalog index files
        index_dir = Path(ABA_ROOT) / "mirror" / ".index"
        operators = set()
        
        if index_dir.exists():
            for index_file in index_dir.glob("*"):
                try:
                    with open(index_file) as f:
                        for line in f:
                            op_name = line.split()[0] if line.strip() else ""
                            # Check if all terms match
                            if all(term in op_name.lower() for term in terms):
                                operators.add(op_name)
                except:
                    pass
        
        # Display results as checkboxes
        for op in sorted(operators):
            checked = op in self.app.operators
            self.query_one("#search-results").mount(
                Checkbox(op, value=checked, id=f"op_{op}")
            )
    
    def on_button_pressed(self, event: Button.Pressed) -> None:
        """Handle button clicks"""
        if event.button.id == "cancel":
            self.app.pop_screen()
        elif event.button.id == "add":
            # Add checked operators to basket
            for checkbox in self.query("#search-results Checkbox"):
                op = checkbox.id.replace("op_", "")
                if checkbox.value:
                    self.app.operators.add(op)
                else:
                    self.app.operators.discard(op)
            self.app.pop_screen()
    
    def action_cancel(self) -> None:
        """Cancel search"""
        self.app.pop_screen()


class ViewBasketScreen(Screen):
    """View and manage operators in basket"""
    
    BINDINGS = [
        Binding("escape", "back", "Back", show=True),
    ]
    
    def compose(self) -> ComposeResult:
        yield Header()
        yield Container(
            Static(f"[bold]Operator Basket ({len(self.app.operators)} operators)[/bold]\n", id="title"),
            Static("Uncheck operators to remove them:\n"),
            VerticalScroll(
                id="basket-list"
            ),
            Horizontal(
                Button("Back", variant="default", id="back"),
                Button("Apply Changes", variant="primary", id="apply"),
                id="button-row"
            ),
            id="basket-container"
        )
        yield Footer()
    
    def on_mount(self) -> None:
        """Display operators"""
        basket_list = self.query_one("#basket-list", VerticalScroll)
        for op in sorted(self.app.operators):
            basket_list.mount(Checkbox(op, value=True, id=f"op_{op}"))
    
    def on_button_pressed(self, event: Button.Pressed) -> None:
        """Handle button clicks"""
        if event.button.id == "back":
            self.app.pop_screen()
        elif event.button.id == "apply":
            # Update basket based on checkboxes
            new_basket = set()
            for checkbox in self.query("#basket-list Checkbox"):
                if checkbox.value:
                    op = checkbox.id.replace("op_", "")
                    new_basket.add(op)
            self.app.operators = new_basket
            self.app.pop_screen()
    
    def action_back(self) -> None:
        """Go back"""
        self.app.pop_screen()


class SummaryScreen(Screen):
    """Summary and final confirmation"""
    
    BINDINGS = [
        Binding("escape", "back", "Back", show=True),
    ]
    
    def compose(self) -> ComposeResult:
        config = self.app.config
        ops_list = "\n".join(f"  • {op}" for op in sorted(list(self.app.operators)[:10]))
        if len(self.app.operators) > 10:
            ops_list += f"\n  ... and {len(self.app.operators) - 10} more"
        
        summary = f"""[bold]Configuration Summary[/bold]

OpenShift:
  • Channel: [cyan]{config.get('ocp_channel', 'stable')}[/cyan]
  • Version: [cyan]{config.get('ocp_version', 'latest')}[/cyan]

Platform & Network:
  • Platform: {config.get('platform', 'bm')}
  • Domain: {config.get('domain', 'example.com')}
  • Network: {config.get('machine_network', '(auto-detect)')}
  • DNS: {config.get('dns_servers', '(auto-detect)')}
  • NTP: {config.get('ntp_servers', '(auto-detect)')}

Operators ({len(self.app.operators)}):
{ops_list or '  (none)'}

"""
        
        yield Header()
        yield VerticalScroll(
            Static(summary, id="summary-text"),
            Horizontal(
                Button("Back", variant="default", id="back"),
                Button("Save Draft", variant="default", id="draft"),
                Button("Apply to aba.conf", variant="success", id="apply"),
                id="button-row"
            ),
            id="summary-container"
        )
        yield Footer()
    
    def on_button_pressed(self, event: Button.Pressed) -> None:
        """Handle button clicks"""
        if event.button.id == "back":
            self.app.pop_screen()
        elif event.button.id == "draft":
            self.app.save_config(draft=True)
            self.app.exit(message="Draft saved to aba.conf.draft")
        elif event.button.id == "apply":
            self.app.save_config(draft=False)
            self.app.exit(message="Configuration saved to aba.conf")
    
    def action_back(self) -> None:
        """Go back to operators"""
        self.app.pop_screen()


class ABATUI(App):
    """ABA Text User Interface"""
    
    CSS = """
    Screen {
        align: center middle;
    }
    
    #welcome-container {
        width: 80;
        height: auto;
        border: solid $primary;
        padding: 2;
        background: $surface;
    }
    
    #channel-container, #version-container, #platform-container,
    #operators-container, #sets-container, #search-container,
    #basket-container, #summary-container {
        width: 90;
        height: auto;
        border: solid $primary;
        padding: 2;
        background: $surface;
    }
    
    #title {
        text-align: center;
        color: $accent;
    }
    
    Button {
        margin: 1;
    }
    
    #button-row, #nav-buttons, #op-buttons {
        align: center middle;
        height: auto;
        margin-top: 1;
    }
    
    Input {
        margin: 1 0;
    }
    
    Select {
        margin: 1 0;
    }
    
    OptionList {
        height: 10;
        margin: 1 0;
        border: solid $primary-lighten-2;
    }
    
    VerticalScroll {
        height: 20;
        border: solid $primary-lighten-2;
        margin: 1 0;
    }
    
    Checkbox {
        margin: 0 1;
    }
    """
    
    def __init__(self):
        super().__init__()
        self.config = {}
        self.operators = set()
        self.background_tasks = {}
    
    def on_mount(self) -> None:
        """Start the application"""
        self.title = "ABA TUI"
        self.sub_title = "OpenShift Installer Wizard"
        self.push_screen(WelcomeScreen())
    
    def start_background_task(self, task_name: str) -> None:
        """Start a background task (placeholder)"""
        # In real implementation, would use run_once
        pass
    
    def write_minimal_config(self) -> None:
        """Write minimal aba.conf for background tasks"""
        conf_file = Path(ABA_ROOT) / "aba.conf"
        
        # Use replace-value-conf via subprocess
        channel = self.config.get('ocp_channel', 'stable')
        version = self.config.get('ocp_version', '')
        platform = self.config.get('platform', 'bm')
        
        if not conf_file.exists():
            conf_file.write_text("# ABA Configuration\nocp_channel=\nocp_version=\nplatform=\n")
        
        # Call bash helper to update config
        subprocess.run(
            ['bash', '-c', f'source {ABA_ROOT}/scripts/include_all.sh && '
             f'replace-value-conf -q -n ocp_channel -v "{channel}" -f {conf_file} && '
             f'replace-value-conf -q -n ocp_version -v "{version}" -f {conf_file} && '
             f'replace-value-conf -q -n platform -v "{platform}" -f {conf_file}'],
            cwd=ABA_ROOT
        )
    
    def save_config(self, draft: bool = False) -> None:
        """Save final configuration to aba.conf"""
        filename = "aba.conf.draft" if draft else "aba.conf"
        conf_file = Path(ABA_ROOT) / filename
        
        # Build operator lists
        ops_csv = ",".join(sorted(self.operators))
        
        # Use replace-value-conf for all settings
        commands = [
            f'replace-value-conf -q -n ocp_channel -v "{self.config.get("ocp_channel", "stable")}" -f {conf_file}',
            f'replace-value-conf -q -n ocp_version -v "{self.config.get("ocp_version", "")}" -f {conf_file}',
            f'replace-value-conf -q -n platform -v "{self.config.get("platform", "bm")}" -f {conf_file}',
            f'replace-value-conf -q -n domain -v "{self.config.get("domain", "example.com")}" -f {conf_file}',
            f'replace-value-conf -q -n machine_network -v "{self.config.get("machine_network", "")}" -f {conf_file}',
            f'replace-value-conf -q -n dns_servers -v "{self.config.get("dns_servers", "")}" -f {conf_file}',
            f'replace-value-conf -q -n ntp_servers -v "{self.config.get("ntp_servers", "")}" -f {conf_file}',
            f'replace-value-conf -q -n ops -v "{ops_csv}" -f {conf_file}',
        ]
        
        script = f'source {ABA_ROOT}/scripts/include_all.sh && ' + ' && '.join(commands)
        subprocess.run(['bash', '-c', script], cwd=ABA_ROOT)


if __name__ == "__main__":
    app = ABATUI()
    app.run()

