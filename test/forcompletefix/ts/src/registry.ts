export class Registry {
  private entries: Record<string, string> = {};

  lookup( key: string ): string | undefined {
    return this.entries[ key ];
  }
}
