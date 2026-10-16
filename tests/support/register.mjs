// Lets node --test import app modules that use the tsconfig "@/..." path alias (extensionless .ts imports).
import {register} from 'node:module';

register('./alias-loader.mjs', import.meta.url);
