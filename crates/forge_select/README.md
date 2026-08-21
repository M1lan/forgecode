# forge_select

A centralized crate for terminal user-interaction prompts.

## Purpose

This crate provides a unified interface for user interactions across the forge
codebase, so no other crate has to talk to a prompt library directly. Prompts
render through a pluggable backend, which is what lets the same call site work
in a plain terminal, in comint mode, and over the JSON frontend protocol.

## Features

- **Select prompts**: Choose from a list of options
- **Confirm prompts**: Yes/no questions
- **Input prompts**: Text input from user
- **Multi-select prompts**: Choose multiple options from a list
- **Row-based select**: Richer rows with preview support (`select_rows`)
- **Pluggable backend**: `install_selector_backend` / `selector_backend`
  redirect prompts to a frontend instead of the TTY
- **Error handling**: Graceful handling of user interruptions

## Usage

The entry point is `ForgeWidget`.

### Select from options

```rust
use forge_select::ForgeWidget;

let options = vec!["Option 1", "Option 2", "Option 3"];
let selected = ForgeWidget::select("Choose an option:", options)
    .with_starting_cursor(1)
    .prompt()?;
```

### Confirm (yes/no)

```rust
use forge_select::ForgeWidget;

let confirmed = ForgeWidget::confirm("Are you sure?")
    .with_default(true)
    .prompt()?;
```

### Text input

```rust
use forge_select::ForgeWidget;

let name = ForgeWidget::input("Enter your name:")
    .allow_empty(false)
    .with_default("John")
    .prompt()?;
```

### Multi-select

```rust
use forge_select::ForgeWidget;

let options = vec!["Red", "Green", "Blue"];
let selected = ForgeWidget::multi_select("Choose colors:", options)
    .prompt()?;
```

## Design

### Builder Pattern

All prompt types use a builder pattern for configuration:

- Create the builder with `ForgeWidget::select()`, `ForgeWidget::confirm()`, etc.
- Configure options with `.with_*()` methods
- Execute with `.prompt()`

### Backends

Prompts do not assume a TTY. `install_selector_backend` swaps in a backend so
a frontend can answer prompts over a protocol instead; `is_comint` and
`is_json` report which frontend mode is active.

## Integration

This crate is used by:

- `forge_main`: For CLI user interactions
- `forge_infra`: For implementing the `UserInfra` trait

Route all user prompts through this crate rather than reaching for a prompt
library directly.
