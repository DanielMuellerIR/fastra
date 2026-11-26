import { Step, StepResult } from 'prosemirror-transform';

/**
 * Invertierbarer Schritt für `doc.attrs.sourceContext`, damit Linux-`replaceSource`
 * auch bei reinen Referenz-Dokumenten ohne sichtbare Absatzänderung sauber
 * über `prosemirror-history` rückgängig gemacht und wiederholt werden kann.
 */
export class SourceContextStep extends Step {
  constructor(nextContext, prevContext = '') {
    super();
    this.nextContext = nextContext;
    this.prevContext = prevContext;
  }

  apply(doc) {
    const updated = doc.type.create(
      { ...doc.attrs, sourceContext: this.nextContext },
      doc.content,
      doc.marks
    );
    return StepResult.ok(updated);
  }

  invert(doc) {
    return new SourceContextStep(this.prevContext, this.nextContext);
  }

  map() {
    return this;
  }

  merge() {
    return null;
  }

  toJSON() {
    return {
      stepType: 'fastraSourceContext',
      nextContext: this.nextContext,
      prevContext: this.prevContext
    };
  }

  static fromJSON(_schema, json) {
    return new SourceContextStep(json.nextContext || '', json.prevContext || '');
  }
}

Step.jsonID('fastraSourceContext', SourceContextStep);
