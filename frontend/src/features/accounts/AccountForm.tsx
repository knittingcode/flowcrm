import { type SyntheticEvent, useId, useState } from 'react';
import { type AccountDetails, EMPTY_DETAILS } from '../../api/accounts.ts';
import { ApiProblem } from '../../api/client.ts';

type Field = keyof AccountDetails;

const FIELDS: readonly { name: Field; label: string; type: string; required: boolean }[] = [
  { name: 'name', label: 'Name', type: 'text', required: true },
  { name: 'website', label: 'Website', type: 'url', required: false },
  { name: 'email', label: 'E-mail address', type: 'email', required: false },
  { name: 'phone', label: 'Phone', type: 'tel', required: false },
];

/** What the API's validation codes mean for each field. */
const MESSAGES: Record<string, string> = {
  REQUIRED: 'This is required.',
  BLANK: 'This is required.',
  TOO_LONG: 'This is too long.',
  INVALID_CHARACTERS: 'This contains characters that cannot be used.',
  INVALID_URL: 'Enter a web address that starts with http:// or https://.',
  INVALID_EMAIL: 'Enter an e-mail address such as name@example.com.',
  INVALID_PHONE: 'Enter a phone number with digits, spaces and + ( ) . / - only.',
};

type FieldErrors = Partial<Record<Field, string>>;

function isField(name: string): name is Field {
  return FIELDS.some((field) => field.name === name);
}

/** The messages of a validation problem, per field; anything else is a general message. */
function describe(error: unknown): { fields: FieldErrors; general: string | null } {
  if (error instanceof ApiProblem && error.status === 422) {
    const fields: FieldErrors = {};
    for (const detail of error.errors) {
      const name = detail.pointer?.replace(/^\//, '') ?? '';
      if (isField(name)) {
        fields[name] = MESSAGES[detail.code] ?? 'This value is not valid.';
      }
    }
    if (Object.keys(fields).length > 0) {
      return { fields, general: null };
    }
  }
  if (error instanceof ApiProblem && error.status === 409) {
    return { fields: {}, general: 'This account is archived and can no longer be changed.' };
  }
  if (error instanceof ApiProblem && error.status === 403) {
    return { fields: {}, general: 'You do not have permission to do this.' };
  }
  if (error instanceof ApiProblem && error.status === 404) {
    return { fields: {}, general: 'This account no longer exists, or you do not have access to it.' };
  }
  if (error instanceof ApiProblem) {
    return { fields: {}, general: `The account could not be saved (request ${error.requestId ?? 'unknown'}).` };
  }
  return { fields: {}, general: 'The API could not be reached.' };
}

/**
 * The form of an account, for creating and editing. The server validates;
 * its answer is shown next to each field. After a successful save of a new
 * account the form is empty again.
 */
export function AccountForm({
  legend,
  submitLabel,
  initial,
  resetOnSuccess,
  onSubmit,
}: {
  legend: string;
  submitLabel: string;
  initial: AccountDetails;
  resetOnSuccess: boolean;
  onSubmit: (details: AccountDetails) => Promise<void>;
}) {
  const id = useId();
  const [details, setDetails] = useState<AccountDetails>(initial);
  const [pending, setPending] = useState(false);
  const [errors, setErrors] = useState<FieldErrors>({});
  const [general, setGeneral] = useState<string | null>(null);

  async function submit(event: SyntheticEvent<HTMLFormElement>) {
    event.preventDefault();
    setPending(true);
    setErrors({});
    setGeneral(null);
    try {
      await onSubmit(details);
      if (resetOnSuccess) {
        setDetails(EMPTY_DETAILS);
      }
    } catch (failure: unknown) {
      const described = describe(failure);
      setErrors(described.fields);
      setGeneral(described.general);
    } finally {
      setPending(false);
    }
  }

  return (
    <form className="record-form" onSubmit={(event) => void submit(event)} aria-busy={pending} noValidate>
      <fieldset disabled={pending}>
        <legend>{legend}</legend>
        {general !== null && (
          <p className="form-error" role="alert">
            {general}
          </p>
        )}
        {FIELDS.map((field) => {
          const error = errors[field.name];
          return (
            <div key={field.name} className="field">
              <label htmlFor={`${id}-${field.name}`}>
                {field.label}
                {field.required ? '' : ' (optional)'}
              </label>
              <input
                id={`${id}-${field.name}`}
                type={field.type}
                required={field.required}
                value={details[field.name]}
                aria-invalid={error !== undefined}
                aria-describedby={error === undefined ? undefined : `${id}-${field.name}-error`}
                onChange={(event) => {
                  setDetails({ ...details, [field.name]: event.target.value });
                }}
              />
              {error !== undefined && (
                <p id={`${id}-${field.name}-error`} className="field-error" role="alert">
                  {error}
                </p>
              )}
            </div>
          );
        })}
        <button type="submit">{pending ? 'Saving…' : submitLabel}</button>
      </fieldset>
    </form>
  );
}
