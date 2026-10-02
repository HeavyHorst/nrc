(function () {
  function resolveAdjacent(rows, selectedIdentity, direction, getIdentity, identitiesEqual) {
    const orderedRows = Array.from(rows || []);
    if (orderedRows.length === 0) return { status: "empty", row: null };

    if (selectedIdentity == null) {
      return {
        status: "target",
        row: direction > 0 ? orderedRows[0] : orderedRows[orderedRows.length - 1],
      };
    }

    const equals = identitiesEqual || ((left, right) => left === right);
    const currentIndex = orderedRows.findIndex((row) => equals(getIdentity(row), selectedIdentity));
    if (currentIndex < 0) return { status: "missing-selection", row: null };

    const nextIndex = Math.max(0, Math.min(orderedRows.length - 1, currentIndex + direction));
    return {
      status: nextIndex === currentIndex ? "boundary" : "target",
      row: orderedRows[nextIndex],
    };
  }

  function sameCompoundIdentity(left, right) {
    return Boolean(left && right && left.convId === right.convId && left.id === right.id);
  }

  function isKeyboardViewActive(activeView, expectedView, visible, panelVisible, hasRows) {
    return Boolean(
      (!activeView || activeView === expectedView) &&
      visible &&
      panelVisible &&
      hasRows
    );
  }

  window.NRCListNavigation = { resolveAdjacent, sameCompoundIdentity, isKeyboardViewActive };
})();
