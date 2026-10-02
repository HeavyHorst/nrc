// =============================================================================
// CUSTOM SELECT - NRC Design System
// =============================================================================
// Light-DOM lifecycle host around a native <select> and the shared picker.
// Usage: <nrc-select><select>...</select></nrc-select>.
// Static data-custom-select fields are wrapped on startup for compatibility.
//
// Options (via data attributes):
//   data-custom-select           - Enable custom select
//   data-custom-select-portal    - Use portal for dropdown (escapes overflow:hidden)
//   data-custom-select-position  - 'bottom' | 'top' (default: 'bottom')
//   Search input is enabled by default for all custom selects
//   data-custom-select-search-placeholder - Search input placeholder text

const CustomSelect = {
    instances: new Map(),

    _uniqueId(base) {
        let id = base;
        let suffix = 2;
        while (document.getElementById(id)) {
            id = `${base}-${suffix}`;
            suffix += 1;
        }
        return id;
    },

    init(select) {
        let wrapper = select.parentElement;
        if (wrapper?.localName !== 'nrc-select') {
            wrapper = document.createElement('nrc-select');
            select.before(wrapper);
            wrapper.append(select);
        }
        return wrapper.mount();
    },

    _mount(select, wrapper) {
        const usePortal = select.hasAttribute('data-custom-select-portal');
        const position = select.getAttribute('data-custom-select-position') || 'bottom';
        const align = select.getAttribute('data-custom-select-align') || 'left';
        const boundarySelector = select.getAttribute('data-custom-select-boundary');
        const searchable = true;
        const searchPlaceholder =
            select.getAttribute('data-custom-select-search-placeholder') || 'SEARCH...';

        const existing = this.instances.get(select);
        if (existing) {
            this._syncSearchable(existing, searchable, searchPlaceholder);
            return existing;
        }

        wrapper.classList.add('custom-select');
        if (searchable) {
            wrapper.classList.add('custom-select--searchable');
        }

        const trigger = document.createElement('button');
        trigger.type = 'button';
        trigger.className = 'custom-select__trigger';
        trigger.id = this._uniqueId(select.id ? `${select.id}-trigger` : 'custom-select-trigger');
        trigger.setAttribute('aria-haspopup', 'listbox');
        trigger.setAttribute('aria-expanded', 'false');
        const labelledBy = select.getAttribute('aria-labelledby');
        const ariaLabel = select.getAttribute('aria-label');
        const explicitLabel = select.id
            ? Array.from(document.querySelectorAll('label[for]')).find((label) => label.htmlFor === select.id)
            : null;
        const nativeLabel = explicitLabel || select.closest('label');
        let assignedLabelId = false;
        if (labelledBy) {
            trigger.setAttribute('aria-labelledby', `${labelledBy} ${trigger.id}`);
        } else if (nativeLabel) {
            if (!nativeLabel.id) {
                nativeLabel.id = this._uniqueId(select.id ? `${select.id}-label` : 'custom-select-label');
                assignedLabelId = true;
            }
            trigger.setAttribute('aria-labelledby', `${nativeLabel.id} ${trigger.id}`);
        } else if (ariaLabel) {
            trigger.setAttribute('aria-label', ariaLabel);
        }
        const nativeLabelFor = explicitLabel?.getAttribute('for') ?? null;
        if (explicitLabel) explicitLabel.htmlFor = trigger.id;

        const dropdown = document.createElement('div');
        dropdown.className = 'custom-select__dropdown';
        dropdown.setAttribute('role', 'listbox');

        const searchInput = document.createElement('input');
        searchInput.type = 'text';
        searchInput.className = 'custom-select__search';
        searchInput.placeholder = searchPlaceholder;
        searchInput.autocomplete = 'off';
        searchInput.setAttribute('aria-label', searchPlaceholder);

        const optionsContainer = document.createElement('div');
        optionsContainer.className = 'custom-select__options';

        dropdown.appendChild(searchInput);
        dropdown.appendChild(optionsContainer);

        wrapper.appendChild(trigger);
        // Only append dropdown to wrapper if not using portal
        if (!usePortal) {
            wrapper.appendChild(dropdown);
        }
        const nativeTabIndex = select.getAttribute('tabindex');
        select.classList.add('custom-select--hidden');
        select.setAttribute('tabindex', '-1');

        const instance = {
            select,
            wrapper,
            trigger,
            dropdown,
            optionsContainer,
            searchInput,
            focusedIndex: -1,
            filteredIndices: [],
            isOpen: false,
            usePortal,
            position,
            portal: null,
            picker: null,
            observer: null,
            handleDocumentClick: null,
            nativeLabel,
            nativeLabelFor,
            assignedLabelId,
            ariaLabelPrefix: ariaLabel,
            registerCell: null,
            handleRegisterCellClick: null,
            nativeTabIndex,
        };

        // Create portal instance if needed
        if (usePortal && typeof Portal !== 'undefined') {
            // A containing portal can supply its logical editor boundary since
            // reparenting removes that editor from the DOM ancestor chain.
            const boundary = wrapper.portalBoundary ?? (boundarySelector ? select.closest(boundarySelector) : null);
            const portalAnchor = trigger.closest('.header-filter-cell') || trigger;
            instance.portal = Portal.create(dropdown, portalAnchor, {
                position: position,
                align: align,
                boundary: boundary,
                matchWidth: true,
                flipIfNeeded: true
            });
        }

        this.instances.set(select, instance);
        this._syncSearchable(instance, searchable, searchPlaceholder);
        this._initPicker(instance);
        this._updateTrigger(instance);
        this._bindEvents(instance);

        return instance;
    },

    _syncSearchable(instance, searchable, searchPlaceholder) {
        instance.wrapper.classList.add('custom-select--searchable');
        instance.searchInput.placeholder = searchPlaceholder;
        instance.searchInput.setAttribute('aria-label', searchPlaceholder);
    },

    _selectOptions(select) {
        return Array.from(select.options).map((option, index) => ({
            value: option.value,
            label: option.label,
            index,
        }));
    },

    _initPicker(instance) {
        instance.picker = CustomPicker.create({
            anchor: instance.trigger,
            dropdown: instance.dropdown,
            searchInput: instance.searchInput,
            optionsContainer: instance.optionsContainer,
            options: this._selectOptions(instance.select),
            selectedValue: instance.select.value,
            placeholder: instance.searchInput.placeholder,
            portal: instance.portal,
            usePortal: false,
            closeOnSelect: false,
            onSelect: (option) => {
                if (instance.select.selectedIndex === option.index) {
                    this._close(instance);
                    return;
                }
                this._selectIndex(instance, option.index);
            },
            onClose: () => {
                instance.isOpen = false;
                instance.wrapper.classList.remove('custom-select--open');
                instance.trigger.setAttribute('aria-expanded', 'false');
            },
        });
    },

    _buildOptions(instance) {
        CustomPicker.setOptions(instance.picker, this._selectOptions(instance.select), instance.select.value);
        instance.filteredIndices = instance.picker.filteredIndices;
        instance.focusedIndex = instance.picker.focusedIndex;
    },

    _updateTrigger(instance) {
        const { select, trigger } = instance;
        trigger.disabled = select.disabled;
        if (select.disabled) this._close(instance);
        const selected = select.options[select.selectedIndex];
        const selectedText = selected ? selected.label : '';
        // The value is a single line: it truncates instead of wrapping the
        // control taller than the fields beside it.
        let value = trigger.querySelector('.custom-select__value');
        if (!value) {
            value = document.createElement('span');
            value.className = 'custom-select__value';
            trigger.textContent = '';
            trigger.append(value);
        }
        value.textContent = selectedText;
        if (instance.ariaLabelPrefix) {
            trigger.setAttribute('aria-label', selectedText
                ? `${instance.ariaLabelPrefix}: ${selectedText}`
                : instance.ariaLabelPrefix);
        }
    },

    _open(instance) {
        if (instance.isOpen || instance.select.disabled) return;
        this.closeAll(instance);
        instance.isOpen = true;
        instance.wrapper.classList.add('custom-select--open');
        instance.trigger.setAttribute('aria-expanded', 'true');
        CustomPicker.setOptions(instance.picker, this._selectOptions(instance.select), instance.select.value);
        CustomPicker.open(instance.picker);
    },

    _close(instance) {
        if (!instance.isOpen) return;
        instance.isOpen = false;
        instance.wrapper.classList.remove('custom-select--open');
        instance.trigger.setAttribute('aria-expanded', 'false');
        CustomPicker.close(instance.picker);
    },

    _toggle(instance) {
        if (instance.isOpen) {
            this._close(instance);
        } else {
            this._open(instance);
        }
    },

    _selectIndex(instance, index) {
        const { select } = instance;
        if (index < 0 || index >= select.options.length) return;

        select.selectedIndex = index;
        select.dispatchEvent(new Event('change', { bubbles: true }));

        this._updateTrigger(instance);
        this._close(instance);
    },

    _updateFocus(instance) {
        CustomPicker._updateFocus(instance.picker);
    },

    _clearFocus(instance) {
        CustomPicker._clearFocus(instance.picker);
    },

    _moveFocus(instance, direction) {
        CustomPicker._moveFocus(instance.picker, direction);
        instance.focusedIndex = instance.picker.focusedIndex;
    },

    _bindSearchInput(instance) {
    },

    _bindEvents(instance) {
        const { trigger, select } = instance;

        trigger.addEventListener('click', (e) => {
            e.preventDefault();
            e.stopPropagation();
            this._toggle(instance);
        });

        instance.registerCell = trigger.closest('.header-filter-cell');
        if (instance.registerCell) {
            instance.handleRegisterCellClick = (e) => {
                if (trigger.contains(e.target) || instance.dropdown.contains(e.target) || select.disabled) return;
                e.preventDefault();
                e.stopPropagation();
                trigger.focus();
                this._toggle(instance);
            };
            instance.registerCell.addEventListener('click', instance.handleRegisterCellClick);
        }

        trigger.addEventListener('keydown', (e) => {
            switch (e.key) {
                case 'Enter':
                case ' ':
                    e.preventDefault();
                    if (instance.isOpen && instance.picker.focusedIndex >= 0) {
                        this._selectIndex(instance, instance.picker.options[instance.picker.focusedIndex].index);
                    } else {
                        this._toggle(instance);
                    }
                    break;
                case 'Escape':
                    if (instance.isOpen) {
                        e.preventDefault();
                        this._close(instance);
                    }
                    break;
                case 'ArrowDown':
                    e.preventDefault();
                    if (!instance.isOpen) {
                        this._open(instance);
                    } else {
                        this._moveFocus(instance, 1);
                    }
                    break;
                case 'ArrowUp':
                    e.preventDefault();
                    if (instance.isOpen) {
                        this._moveFocus(instance, -1);
                    }
                    break;
                case 'Home':
                    if (instance.isOpen) {
                        e.preventDefault();
                        instance.picker.focusedIndex = instance.picker.filteredIndices[0] ?? -1;
                        CustomPicker._updateFocus(instance.picker);
                    }
                    break;
                case 'End':
                    if (instance.isOpen) {
                        e.preventDefault();
                        instance.picker.focusedIndex = instance.picker.filteredIndices[instance.picker.filteredIndices.length - 1] ?? -1;
                        CustomPicker._updateFocus(instance.picker);
                    }
                    break;
            }
        });

        instance.handleDocumentClick = (e) => {
            if (!instance.wrapper.contains(e.target) && !instance.dropdown.contains(e.target)) {
                this._close(instance);
            }
        };
        document.addEventListener('click', instance.handleDocumentClick);

        instance.observer = new MutationObserver(() => {
            if (this.instances.get(select) !== instance) return;
            this._buildOptions(instance);
            this._updateTrigger(instance);
        });
        instance.observer.observe(select, {
            childList: true, subtree: true, characterData: true,
            attributes: true, attributeFilter: ['selected', 'disabled', 'value', 'label'],
        });

        instance.handleChange = () => this.refresh(select);
        select.addEventListener('change', instance.handleChange);
        instance.handleReset = (event) => {
            if (event.target !== select.form) return;
            // A microtask can run before a reset button's default action finishes.
            clearTimeout(instance.resetTimer);
            instance.resetTimer = setTimeout(() => {
                if (this.instances.get(select) === instance) this.refresh(select);
            }, 0);
        };
        document.addEventListener('reset', instance.handleReset, true);

        // Keep native programmatic changes synchronous with the visible control.
        const self = this;
        for (const property of ['value', 'selectedIndex', 'disabled']) {
            const descriptor = Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, property);
            Object.defineProperty(select, property, {
                configurable: true,
                get() { return descriptor.get.call(this); },
                set(value) { descriptor.set.call(this, value); self.refresh(select); }
            });
        }
    },

    refresh(select) {
        const instance = this.instances.get(select);
        if (instance) {
            this._buildOptions(instance);
            this._updateTrigger(instance);
        }
    },

    close(select) {
        const instance = this.instances.get(select);
        if (instance) this._close(instance);
    },

    destroy(select) {
        const instance = this.instances.get(select);
        if (!instance) return;

        this._close(instance);
        instance.observer?.disconnect();
        select.removeEventListener('change', instance.handleChange);
        document.removeEventListener('reset', instance.handleReset, true);
        clearTimeout(instance.resetTimer);
        if (instance.handleDocumentClick) {
            document.removeEventListener('click', instance.handleDocumentClick);
        }
        if (instance.registerCell && instance.handleRegisterCellClick) {
            instance.registerCell.removeEventListener('click', instance.handleRegisterCellClick);
        }
        CustomPicker.destroy(instance.picker);
        instance.portal?.destroy();
        this.instances.delete(select);

        delete select.value;
        delete select.selectedIndex;
        delete select.disabled;
        select.classList.remove('custom-select--hidden');
        if (instance.nativeTabIndex == null) select.removeAttribute('tabindex');
        else select.setAttribute('tabindex', instance.nativeTabIndex);
        if (instance.nativeLabel) {
            if (instance.nativeLabelFor == null) instance.nativeLabel.removeAttribute('for');
            else instance.nativeLabel.setAttribute('for', instance.nativeLabelFor);
            if (instance.assignedLabelId) instance.nativeLabel.removeAttribute('id');
        }
        instance.trigger.remove();
        instance.dropdown.remove();
    },

    closeAll(exceptInstance = null) {
        this.instances.forEach((instance) => {
            if (instance !== exceptInstance && instance.isOpen) {
                this._close(instance);
            }
        });
    },

    initAll(selector = '[data-custom-select]') {
        document.querySelectorAll(selector).forEach(select => this.init(select));
    }
};

window.CustomSelect = CustomSelect;

class NRCSelect extends HTMLElement {
    connectedCallback() {
        this.observer = new MutationObserver(() => this.mount());
        // Also handles children arriving after parser connection and replacement
        // of the native select without replacing the host.
        this.observer.observe(this, { childList: true });
        this.mount();
    }

    mount() {
        if (!this.isConnected) return;
        const select = Array.from(this.children).find(child => child.localName === 'select');
        if (this.select !== select) {
            this.dispose();
            this.select = select;
        }
        if (!select) return;
        const existing = CustomSelect.instances.get(select);
        if (existing?.wrapper === this) return existing;
        if (existing) CustomSelect.destroy(select);
        return CustomSelect._mount(select, this);
    }

    dispose() {
        if (CustomSelect.instances.get(this.select)?.wrapper === this) CustomSelect.destroy(this.select);
        this.select = null;
    }

    disconnectedCallback() {
        this.observer?.disconnect();
        this.observer = null;
        this.dispose();
    }
}

customElements.define('nrc-select', NRCSelect);

function initHeaderRegisterCells() {
    document.addEventListener('click', (event) => {
        const cell = event.target.closest('.header-filter-cell');
        if (!cell || event.target.closest('button, input, select, label, a')) return;

        const controls = Array.from(cell.querySelectorAll('button, input, select'))
            .filter((control) => !control.disabled && !control.classList.contains('custom-select--hidden'));
        if (controls.length !== 1) return;

        const control = controls[0];
        if (control.matches('input[type="checkbox"], input[type="radio"], button')) {
            control.click();
        } else {
            control.focus();
        }
    });
}

document.addEventListener('DOMContentLoaded', () => {
    CustomSelect.initAll();
    initHeaderRegisterCells();
});
