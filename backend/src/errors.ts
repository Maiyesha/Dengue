export class ApiError extends Error {
  constructor(
    public readonly status: number,
    public readonly code: string,
    message: string,
    public readonly detail?: object,
  ) {
    super(message);
    this.name = 'ApiError';
  }
}
