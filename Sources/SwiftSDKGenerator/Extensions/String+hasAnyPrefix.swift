extension String {
    func hasAnyPrefix(from array: [String]) -> Bool {
        for item in array {
            if self.hasPrefix(item) {
                return true
            }
        }
        return false
    }
}
