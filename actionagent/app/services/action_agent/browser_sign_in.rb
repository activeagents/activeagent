# frozen_string_literal: true

module ActionAgent
  # Used to sign a project's sandbox browser in to the app with a sign_in
  # ProjectSecret, from the Rails process, so the credentials never reach a
  # model: they are typed into the form by SandboxBrowserDriver and appear in
  # no tool argument, tool result, log line, span or recorded action. The
  # browser's own recording masks what is typed.
  #
  # The form is found on the secret's login_url: the password field, then the
  # login field and the submit button near it, unless the secret names them
  # with CSS selectors. Afterwards the password field is emptied when the
  # browser is still on the login page, so a later page snapshot cannot show
  # it.
  class BrowserSignIn
    # The outcome, as the explorer's sign_in tool and the test account step
    # report it:
    #
    #   signed_in    the browser left the login page
    #   failed       it stayed there, as after a wrong password
    #   unsupported  the login page has no password field, as with sign-in
    #                through another site (OAuth or SSO)
    #   error        the browser could not be driven
    Result = Struct.new(:status, :message, keyword_init: true) do
      def signed_in?
        status == "signed_in"
      end

      def to_h
        { status: status, signed_in: signed_in?, message: message }
      end
    end

    MESSAGES = {
      "signed_in" => "Signed in: the browser left the login page.",
      "failed" => "The browser is still on the login page after submitting the form. Check the login and password.",
      "unsupported" => "The login page has no password field, so the app's sign-in (OAuth or SSO only) is not " \
                       "supported in the sandbox.",
      "error" => "The sandbox's browser could not be driven to sign in."
    }.freeze

    PASSWORD_TARGET = '[data-aa-sign-in="password"]'
    LOGIN_TARGET = '[data-aa-sign-in="login"]'
    SUBMIT_TARGET = '[data-aa-sign-in="submit"]'
    LOGIN_CANDIDATES = 'input[type="email"], input[autocomplete="username"], input[autocomplete="email"], ' \
                       'input[name*="email" i], input[name*="login" i], input[name*="user" i], input[type="text"]'
    # How long a sign-in that has not left the login page yet is given before
    # it counts as failed.
    SETTLE_SECONDS = 2
    CLEAR_PASSWORDS = "() => { document.querySelectorAll('input[type=\"password\"]').forEach((el) => { el.value = ''; }); return true; }"

    # @param sandbox [SandboxSession] with its browser running
    # @param secret [ProjectSecret] a sign_in secret
    # @return [Result]
    def self.call(sandbox, secret, driver: nil)
      new(sandbox, secret, driver).call
    end

    def initialize(sandbox, secret, driver)
      @sandbox = sandbox
      @secret = secret
      @driver = driver
    end

    def call
      credentials = @secret.sign_in_credentials
      return result("failed") if credentials["password"].blank?

      driver.open(credentials["login_url"])
      marks = driver.evaluate(mark_fields(credentials))
      return result("unsupported") unless marks.is_a?(Hash) && marks["password"] == true

      login_path = marks["path"]
      driver.type(LOGIN_TARGET, credentials["login"]) if marks["login"] == true && credentials["login"].present?
      if marks["submit"] == true
        driver.type(PASSWORD_TARGET, credentials["password"])
        driver.click(SUBMIT_TARGET)
      else
        driver.type(PASSWORD_TARGET, credentials["password"], submit: true)
      end

      return result("signed_in") if left?(login_path)

      driver.evaluate(CLEAR_PASSWORDS)
      result("failed")
    rescue SandboxBrowserDriver::Error => e
      Rails.logger.warn("[ActionAgent] sign-in in sandbox #{@sandbox.session_id} failed: #{e.message}")
      clear_quietly
      result("error")
    end

    private

    def driver
      @driver ||= SandboxBrowserDriver.new(@sandbox)
    end

    def result(status)
      Result.new(status: status, message: MESSAGES.fetch(status))
    end

    # Whether the browser shows a page other than +login_path+, checking
    # again after SETTLE_SECONDS for an app that redirects late.
    def left?(login_path)
      path = driver.current_path
      return true if path.present? && path != login_path

      driver.wait(SETTLE_SECONDS)
      path = driver.current_path
      path.present? && path != login_path
    end

    def clear_quietly
      @driver&.evaluate(CLEAR_PASSWORDS)
    rescue SandboxBrowserDriver::Error
      nil
    end

    # The page function that finds the sign-in form and marks its fields
    # with data-aa-sign-in, answering which it found. Selectors from the
    # secret are passed as JSON string literals.
    def mark_fields(credentials)
      password, login, submit = credentials.values_at("password_field", "login_field", "submit_field").map(&:to_json)
      <<~JS.squish
        () => {
          const visible = (el) => !!(el && (el.offsetWidth || el.offsetHeight || el.getClientRects().length));
          const pick = (selector) => { try { return selector ? document.querySelector(selector) : null; } catch (e) { return null; } };
          document.querySelectorAll('[data-aa-sign-in]').forEach((el) => el.removeAttribute('data-aa-sign-in'));
          const password = pick(#{password}) || [...document.querySelectorAll('input[type="password"]')].find(visible);
          if (!password) return { password: false, path: location.pathname };
          const scope = password.form || document;
          const login = pick(#{login}) || [...scope.querySelectorAll(#{LOGIN_CANDIDATES.to_json})].find((el) => el !== password && visible(el));
          const submit = pick(#{submit}) || scope.querySelector('button[type="submit"], input[type="submit"]') || scope.querySelector('button:not([type])');
          password.setAttribute('data-aa-sign-in', 'password');
          if (login) login.setAttribute('data-aa-sign-in', 'login');
          if (submit) submit.setAttribute('data-aa-sign-in', 'submit');
          return { password: true, login: !!login, submit: !!submit, path: location.pathname };
        }
      JS
    end
  end
end
