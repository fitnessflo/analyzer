// PARAM: --set solver td3 --enable ana.int.interval --enable exp.partition-arrays.enabled  --set ana.activated "['base','threadid','threadflag','expRelation','octagon','mallocWrapper']" --set exp.privatization none
// These examples were cases were we saw issues of not reaching a fixpoint during development of the octagon domain. Since those issues might
// resurface, these tests without asserts are included
int main(int argc, char const *argv[])
{
    int j = -1;
    int digits = 0;

    int hour12;
    int number_value;

    if (hour12 > 12) {
        hour12 -= 12;
    }

    digits = 0;

    while (j < 9)
    {
        number_value /= 10;
        j++;
    }

    return 0;
}
