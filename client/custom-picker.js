// =============================================================================
// CUSTOM PICKER - NRC Design System
// =============================================================================
// Shared searchable dropdown behavior for custom selects and dynamic pickers.

const CustomPicker = {
    instances: new Set(),

    create(config) {
        const dropdown = config.dropdown || document.createElement('div');
        dropdown.className = config.dropdownClass || 'custom-select__dropdown';
        dropdown.setAttribute('role', config.role || 'listbox');

        const searchInput = config.searchInput || document.createElement('input');
        searchInput.type = 'text';
        searchInput.className = config.searchClass || 'custom-select__search';
        searchInput.placeholder = config.placeholder || 'SEARCH...';
        searchInput.autocomplete = 'off';
        searchInput.setAttribute('aria-label', searchInput.placeholder);

        const optionsContainer = config.optionsContainer || document.createElement('div');
        optionsContainer.className = config.optionsClass || 'custom-select__options';

        if (!config.dropdown) {
            dropdown.appendChild(searchInput);
            dropdown.appendChild(optionsContainer);
        }

        const instance = {
            anchor: config.anchor,
            dropdown,
            searchInput,
            optionsContainer,
            options: config.options || [],
            selectedValue: config.selectedValue ?? null,
            focusedIndex: -1,
            filteredIndices: [],
            isOpen: false,
            closeOnSelect: config.closeOnSelect ?? true,
            allowCustomValue: Boolean(config.allowCustomValue),
            onSelect: config.onSelect || (() => {}),
            onCustomValue: config.onCustomValue || (() => {}),
            onClose: config.onClose || (() => {}),
            portal: null,
            ownsPortal: false,
        };

        if (config.portal) {
            instance.portal = config.portal;
        } else if (config.usePortal !== false && typeof Portal !== 'undefined') {
            instance.portal = Portal.create(dropdown, config.anchor, {
                position: config.position || 'bottom',
                align: config.align || 'left',
                matchWidth: config.matchWidth ?? true,
                flipIfNeeded: config.flipIfNeeded ?? true,
                offsetY: config.offsetY ?? 0,
                offsetX: config.offsetX ?? 0,
            });
            instance.ownsPortal = true;
        }

        this._bindEvents(instance);
        this.instances.add(instance);
        return instance;
    },

    setOptions(instance, options, selectedValue = instance.selectedValue) {
        instance.options = options || [];
        instance.selectedValue = selectedValue ?? null;
        this._buildOptions(instance);
        this._updateFocus(instance);
    },

    open(instance) {
        if (instance.isOpen) return;
        this.closeAll(instance);
        instance.isOpen = true;
        instance.focusedIndex = this._selectedIndex(instance);
        this._buildOptions(instance);
        this._updateFocus(instance);

        if (instance.portal) {
            instance.portal.show();
        }

        instance.searchInput.focus();
        instance.searchInput.select();
    },

    close(instance) {
        if (!instance.isOpen) return;
        instance.isOpen = false;
        instance.focusedIndex = -1;
        this._clearFocus(instance);

        if (instance.portal) {
            instance.portal.hide();
        }

        if (instance.searchInput.value) {
            instance.searchInput.value = '';
            this._buildOptions(instance);
        }

        instance.onClose(instance);
    },

    destroy(instance) {
        this.close(instance);
        if (instance.ownsPortal && instance.portal) {
            instance.portal.destroy();
        }
        this.instances.delete(instance);
    },

    closeAll(exceptInstance = null) {
        this.instances.forEach((instance) => {
            if (instance !== exceptInstance && instance.isOpen) {
                this.close(instance);
            }
        });
    },

    _buildOptions(instance) {
        const query = instance.searchInput.value.trim().toLowerCase();
        instance.optionsContainer.innerHTML = '';
        instance.filteredIndices = [];

        instance.options.forEach((option, index) => {
            const label = String(option.label ?? '');
            if (query && !option.alwaysVisible && !label.toLowerCase().includes(query)) {
                return;
            }

            const div = document.createElement('div');
            div.className = 'custom-select__option';
            div.setAttribute('role', 'option');
            div.setAttribute('data-index', index);
            div.setAttribute('data-value', option.value);
            div.textContent = label;

            if (String(option.value) === String(instance.selectedValue)) {
                div.classList.add('custom-select__option--selected');
                div.setAttribute('aria-selected', 'true');
            }

            instance.optionsContainer.appendChild(div);
            instance.filteredIndices.push(index);
        });

        if (instance.filteredIndices.length === 0) {
            const empty = document.createElement('div');
            empty.className = 'custom-select__empty';
            empty.textContent = 'NO RESULTS';
            instance.optionsContainer.appendChild(empty);
            instance.focusedIndex = -1;
            return;
        }

        if (!instance.filteredIndices.includes(instance.focusedIndex)) {
            const selectedIndex = this._selectedIndex(instance);
            instance.focusedIndex = instance.filteredIndices.includes(selectedIndex)
                ? selectedIndex
                : instance.filteredIndices[0];
        }
    },

    _selectedIndex(instance) {
        return instance.options.findIndex((option) => String(option.value) === String(instance.selectedValue));
    },

    _selectIndex(instance, index) {
        if (index < 0 || index >= instance.options.length) return;
        const option = instance.options[index];
        instance.selectedValue = option.value;
        instance.onSelect(option, index, instance);
        this._buildOptions(instance);
        if (instance.closeOnSelect) {
            this.close(instance);
        }
    },

    _updateFocus(instance) {
        this._clearFocus(instance);
        if (instance.focusedIndex < 0) return;

        const focused = instance.optionsContainer.querySelector(
            `.custom-select__option[data-index="${instance.focusedIndex}"]`
        );
        if (focused) {
            focused.classList.add('custom-select__option--focused');
            focused.scrollIntoView({ block: 'nearest' });
        }
    },

    _clearFocus(instance) {
        instance.optionsContainer.querySelectorAll('.custom-select__option--focused')
            .forEach(el => el.classList.remove('custom-select__option--focused'));
    },

    _moveFocus(instance, direction) {
        const indices = instance.filteredIndices;
        if (indices.length === 0) {
            instance.focusedIndex = -1;
            return;
        }

        const currentPos = indices.indexOf(instance.focusedIndex);
        if (currentPos === -1) {
            instance.focusedIndex = direction > 0 ? indices[0] : indices[indices.length - 1];
        } else {
            const nextPos = Math.max(0, Math.min(indices.length - 1, currentPos + direction));
            instance.focusedIndex = indices[nextPos];
        }

        this._updateFocus(instance);
    },

    _bindEvents(instance) {
        instance.searchInput.addEventListener('input', () => {
            instance.navigated = false;
            this._buildOptions(instance);
            this._updateFocus(instance);
        });

        instance.searchInput.addEventListener('keydown', (e) => {
            if (['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(e.key)) instance.navigated = true;
            switch (e.key) {
                case 'ArrowDown':
                    e.preventDefault();
                    this._moveFocus(instance, 1);
                    break;
                case 'ArrowUp':
                    e.preventDefault();
                    this._moveFocus(instance, -1);
                    break;
                case 'Home':
                    e.preventDefault();
                    instance.focusedIndex = instance.filteredIndices[0] ?? -1;
                    this._updateFocus(instance);
                    break;
                case 'End':
                    e.preventDefault();
                    instance.focusedIndex = instance.filteredIndices[instance.filteredIndices.length - 1] ?? -1;
                    this._updateFocus(instance);
                    break;
                case 'Enter':
                    const customValue = instance.searchInput.value.trim();
                    const exactMatch = instance.filteredIndices.find((index) => {
                        const option = instance.options[index];
                        return String(option.label ?? '').toLowerCase() === customValue.toLowerCase()
                            || String(option.value ?? '').toLowerCase() === customValue.toLowerCase();
                    });
                    if (instance.allowCustomValue && customValue && !instance.navigated) {
                        e.preventDefault();
                        if (exactMatch !== undefined) this._selectIndex(instance, exactMatch);
                        else {
                            instance.onCustomValue(customValue, instance);
                            if (instance.closeOnSelect) this.close(instance);
                        }
                    } else if (instance.focusedIndex >= 0) {
                        e.preventDefault();
                        this._selectIndex(instance, instance.focusedIndex);
                    }
                    break;
                case 'Escape':
                    e.preventDefault();
                    this.close(instance);
                    instance.anchor?.focus?.();
                    break;
            }
        });

        instance.dropdown.addEventListener('click', (e) => {
            const option = e.target.closest('.custom-select__option');
            if (option) {
                this._selectIndex(instance, parseInt(option.getAttribute('data-index'), 10));
            }
        });

        instance.dropdown.addEventListener('mouseover', (e) => {
            const option = e.target.closest('.custom-select__option');
            if (option) {
                instance.navigated = true;
                instance.focusedIndex = parseInt(option.getAttribute('data-index'), 10);
                this._updateFocus(instance);
            }
        });
    },
};

window.CustomPicker = CustomPicker;
