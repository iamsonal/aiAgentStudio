function isPlaceholderCondition(label) {
    const normalized = (label || '').trim().toLowerCase();
    return !normalized || normalized === 'default condition' || /^condition \d+$/.test(normalized);
}

export function computeGraphDiagnostics(cy, capabilities = [], parallelCallingEnabled = true) {
    const diagnostics = {
        warnings: [],
        warningCount: 0,
        missingConditionCount: 0,
        unknownToolCount: 0,
        parallelConflictCount: 0,
        sourceConflictCount: 0
    };

    if (!cy) {
        return diagnostics;
    }

    const knownTools = new Set((capabilities || []).map((cap) => cap.capabilityName).filter(Boolean));

    cy.edges('[type="exclusive"]').forEach((edge) => {
        if (isPlaceholderCondition(edge.data('condition'))) {
            diagnostics.missingConditionCount += 1;
        }
    });

    cy.nodes('[nodeType="step"]').forEach((node) => {
        const tools = JSON.parse(node.data('tools') || '[]');
        for (const toolName of tools) {
            if (toolName && knownTools.size > 0 && !knownTools.has(toolName)) {
                diagnostics.unknownToolCount += 1;
            }
        }

        if (parallelCallingEnabled !== true && tools.length > 1) {
            diagnostics.parallelConflictCount += 1;
        }

        const outgoingTypes = new Set();
        node.outgoers('edge').forEach((edge) => {
            const targetType = edge.target().data('nodeType');
            if (targetType === 'end') return;
            outgoingTypes.add(edge.data('type') || edge.data('edgeType') || 'sequential');
        });
        if (outgoingTypes.size > 1) {
            diagnostics.sourceConflictCount += 1;
        }
    });

    if (diagnostics.missingConditionCount > 0) {
        diagnostics.warnings.push(
            diagnostics.missingConditionCount + ' branch condition' + (diagnostics.missingConditionCount === 1 ? '' : 's') + ' need attention'
        );
    }
    if (diagnostics.unknownToolCount > 0) {
        diagnostics.warnings.push(
            diagnostics.unknownToolCount + ' tool reference' + (diagnostics.unknownToolCount === 1 ? '' : 's') + ' no longer match current capabilities'
        );
    }
    if (diagnostics.parallelConflictCount > 0) {
        diagnostics.warnings.push(
            diagnostics.parallelConflictCount + ' parallel step' + (diagnostics.parallelConflictCount === 1 ? '' : 's') + ' conflict with agent settings'
        );
    }
    if (diagnostics.sourceConflictCount > 0) {
        diagnostics.warnings.push(diagnostics.sourceConflictCount + ' node' + (diagnostics.sourceConflictCount === 1 ? '' : 's') + ' mix outgoing rule types');
    }

    diagnostics.warningCount = diagnostics.warnings.length;
    return diagnostics;
}
