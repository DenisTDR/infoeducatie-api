module Robotics
  class TransitionError < StandardError
    attr_reader :code, :status

    def initialize(code, message, status: :conflict)
      @code = code
      @status = status
      super(message)
    end
  end
end
