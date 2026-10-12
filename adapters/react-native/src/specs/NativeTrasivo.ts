import type { TurboModule } from 'react-native';
import { TurboModuleRegistry } from 'react-native';

// JSON keeps the transport independent of Codegen's dictionary restrictions.
// The public API and both native endpoints validate the operation-specific data.
export interface Spec extends TurboModule {
  execute(payload: string): Promise<string>;
  addListener(eventName: string): void;
  removeListeners(count: number): void;
}

export default TurboModuleRegistry.get<Spec>('Trasivo');
