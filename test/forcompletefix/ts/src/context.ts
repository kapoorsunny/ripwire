import { RequestView } from './request';

export interface IncomingRequest {
  url: string;
  headers: Record<string, string>;
}

export class Context {
  request: RequestView;
  state: Record<string, unknown> = {};

  constructor( req: IncomingRequest ) {
    this.request = new RequestView( req );
  }
}
