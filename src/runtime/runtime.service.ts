import { Injectable } from '@nestjs/common';

export interface RuntimeInfo {
  application: string;
  version: string;
  environment: string;
  pod: string;
  namespace: string;
  node: string;
  delivery: string;
}

@Injectable()
export class RuntimeService {
  getInfo(): RuntimeInfo {
    return {
      application: process.env.APP_NAME ?? 'kubescope',
      version: process.env.APP_VERSION ?? 'dev',
      environment: process.env.APP_ENV ?? 'local',
      pod: process.env.POD_NAME ?? 'local',
      namespace: process.env.POD_NAMESPACE ?? 'local',
      node: process.env.NODE_NAME ?? 'local',
      delivery: 'GitOps con GitHub Actions',
    };
  }
}
