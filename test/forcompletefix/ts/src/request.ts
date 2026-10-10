import type { IncomingRequest } from './context';

export class RequestView {
  constructor( private raw: IncomingRequest ) {}

  // The host the request context was created for.
  get contextHost(): string {
    const bag: any = this.raw;
    return bag.lookup( 'host' ) ?? '';
  }

  get path(): string {
    return this.raw.url;
  }
}
