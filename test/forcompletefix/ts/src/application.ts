import { Context, IncomingRequest } from './context';

function freshState(): Record<string, unknown> {
  return { startedAt: Date.now() };
}

export class Application {
  private contexts = 0;

  // Build the per-request context object every middleware receives.
  createContext(
    req: IncomingRequest,
  ): Context {
    const ctx = new Context( req );
    ctx.state = freshState();
    this.contexts += 1;
    return ctx;
  }

  handle( req: IncomingRequest ): Context {
    return this.createContext( req );
  }
}
